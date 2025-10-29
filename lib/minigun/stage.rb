# frozen_string_literal: true

module Minigun
  # Unified context for all stage execution (producers and workers)
  StageContext = Struct.new(
    # Common to all stages
    :pipeline,
    :stage_name,
    :dag,
    :runtime_edges,
    :stage_input_queues,
    :stage_stats,
    # Worker-specific (nil/empty for producers)
    :input_queue,
    :sources_expected,
    :sources_done,
    :executor,
    keyword_init: true
  )

  # Base class for all execution units (stages and pipelines)
  # Implements the Composite pattern where Pipeline is a composite Stage
  # Also handles loop-based stages (stages that manage their own input loop)
  class Stage
    attr_reader :name, :options, :block

    def initialize(name:, block: nil, options: {})
      @name = name
      @block = block
      @options = options
    end

    # Get the queue size for this stage
    # Returns nil for unbounded queues (0, Float::INFINITY, nil)
    # Returns integer for bounded queues (SizedQueue)
    def queue_size
      size = @options[:queue_size]

      # Use global default if not specified
      size = Minigun.default_queue_size if size.nil?

      # Check for unbounded indicators
      return nil if [0, Float::INFINITY, false].include?(size)

      size.to_i
    end

    # Execute the stage with the given context
    # For loop-based stages, this receives input_queue and output_queue
    def execute(context, input_queue, output_queue, _stage_stats)
      if @block
        context.instance_exec(input_queue, output_queue, &@block)
      elsif respond_to?(:call)
        call_with_arity(input_queue, output_queue, &output_queue.to_proc)
      end
    end

    # Run the worker loop for loop-based stages
    # Loop-based stages manage their own input loop
    def run_worker_loop(stage_ctx)
      # Create wrapped queues
      input_queue = create_input_queue(stage_ctx)
      output_queue = create_output_queue(stage_ctx)

      # Execute with both queues (block manages its own loop)
      context = stage_ctx.pipeline.context
      execute(context, input_queue, output_queue, stage_ctx.stage_stats)

      # Send END signals to downstream
      send_end_signals(stage_ctx)
    end

    # Get execution context configuration for this stage
    def execution_context
      @options[:_execution_context]
    end

    # Hash representation (for test compatibility)
    def to_h
      hash = { name: @name, options: @options }
      hash[:block] = @block if @block
      hash
    end

    # Hash-like access (for test compatibility)
    def [](key)
      case key
      when :name then @name
      when :options then @options
      when :block then @block
      end
    end

    # Type name for logging purposes
    def log_type
      'Worker'
    end

    # Execution strategy: :autonomous, :streaming, or :composite
    def run_mode
      :streaming # Default: process stream of items in worker loop
    end

    private

    # Create wrapped input queue for this stage
    def create_input_queue(stage_ctx)
      InputQueue.new(
        stage_ctx.input_queue,
        stage_ctx.stage_name,
        stage_ctx.sources_expected,
        stage_stats: stage_ctx.stage_stats
      )
    end

    # Create wrapped output queue for this stage
    def create_output_queue(stage_ctx)
      downstream = stage_ctx.dag.downstream(stage_ctx.stage_name)
      downstream_queues = downstream.filter_map { |ds| stage_ctx.stage_input_queues[ds] }
      OutputQueue.new(
        stage_ctx.stage_name,
        downstream_queues,
        stage_ctx.stage_input_queues,
        stage_ctx.runtime_edges,
        stage_stats: stage_ctx.stage_stats
      )
    end

    # Consolidated end signal logic used by all stage types
    def send_end_signals(stage_ctx)
      dag_downstream = stage_ctx.dag.downstream(stage_ctx.stage_name)
      dynamic_targets = stage_ctx.runtime_edges[stage_ctx.stage_name].to_a
      all_targets = (dag_downstream + dynamic_targets).uniq

      all_targets.each do |target|
        next unless stage_ctx.stage_input_queues[target]

        stage_ctx.stage_input_queues[target] << Message.end_signal(source: stage_ctx.stage_name)
      end
    end

    # Call the stage's #call method with appropriate args based on arity
    def call_with_arity(*args, &)
      arity = method(:call).arity.abs
      call(*args[...arity], &)
    end
  end

  # Producer stage - executes once, no input
  class ProducerStage < Stage
    def execute(context, _input_queue, output_queue, _stage_stats)
      if @block
        context.instance_exec(output_queue, &@block)
      elsif respond_to?(:call)
        call_with_arity(output_queue, &output_queue.to_proc)
      end
    end

    def log_type
      'Producer'
    end

    def run_mode
      :autonomous # Generates data independently
    end

    def run_worker_loop(stage_ctx)
      stage_stats = stage_ctx.stage_stats
      stage_stats.start!
      log_info(stage_ctx, 'Starting')

      begin
        # Execute before hooks
        execute_hooks(stage_ctx, :before)

        # Create output queue
        output_queue = create_output_queue(stage_ctx)

        # Execute producer block directly (ProducerStage doesn't use executor since it's autonomous)
        context = stage_ctx.pipeline.context
        execute(context, nil, output_queue, stage_stats)

        # Execute after hooks
        execute_hooks(stage_ctx, :after)
      rescue StandardError => e
        log_error(stage_ctx, "Error: #{e.message}")
        log_error(stage_ctx, e.backtrace.join("\n"))
      ensure
        stage_ctx.stage_stats.finish!
        log_info(stage_ctx, 'Done')
        send_end_signals(stage_ctx)
      end
    end

    private

    def execute_hooks(ctx, type)
      ctx.pipeline.execute_stage_hooks(type, ctx.stage_name)
    end

    def log_info(ctx, msg)
      Minigun.logger.info "[Pipeline:#{ctx.pipeline.name}][Producer:#{ctx.stage_name}] #{msg}"
    end

    def log_error(ctx, msg)
      Minigun.logger.error "[Pipeline:#{ctx.pipeline.name}][Producer:#{ctx.stage_name}] #{msg}"
    end
  end

  # Consumer/Processor stage - loops on input, processes items
  class ConsumerStage < Stage
    def execute(context, input_queue, output_queue, stage_stats)
      # Consumer stages pop from input_queue and process items
      loop do
        item = input_queue.pop

        # Handle END signal or AllUpstreamsDone
        break if item.is_a?(AllUpstreamsDone)
        break if item.is_a?(Message) && item.end_of_stream?

        # Execute the block or call method with the item, tracking per-item latency
        begin
          start_time = Time.now if stage_stats

          if @block
            context.instance_exec(item, output_queue, &@block)
          elsif respond_to?(:call)
            call_with_arity(item, output_queue, &output_queue.to_proc)
          end

          # Record per-item latency for bottleneck detection
          stage_stats&.record_latency(Time.now - start_time)
        rescue StandardError => e
          # Log item-level errors but continue processing
          Minigun.logger.error "[Stage:#{name}] Error processing item: #{e.message}"
          Minigun.logger.debug e.backtrace.join("\n") if Minigun.logger.debug?
        end
      end
    end

    def run_worker_loop(stage_ctx)
      # Store stage_stats for access during execute
      stage_stats = stage_ctx.stage_stats
      stage_stats.start!

      # Execute before hooks
      stage_ctx.pipeline.send(:execute_stage_hooks, :before, stage_ctx.stage_name)

      # Create wrapped queues
      input_queue = create_input_queue(stage_ctx)
      output_queue = create_output_queue(stage_ctx)

      # Execute via executor (defines HOW: inline/threaded/process)
      context = stage_ctx.pipeline.context
      stage_ctx.executor.execute_stage(self, context, input_queue, output_queue, stage_stats)

      # Execute after hooks
      stage_ctx.pipeline.send(:execute_stage_hooks, :after, stage_ctx.stage_name)

      # Flush and cleanup
      flush_if_needed(stage_ctx, output_queue)
      send_end_signals(stage_ctx)
    end

    private

    def flush_if_needed(stage_ctx, output_queue)
      return unless respond_to?(:flush)

      context = stage_ctx.pipeline.context
      flush(context, output_queue)
    end
  end

  # Accumulator stage - batches items before passing to consumer
  # Collects N items, then emits them as a batch
  class AccumulatorStage < ConsumerStage
    attr_reader :max_size, :max_wait

    def initialize(name:, block: nil, options: {})
      super
      @max_size = options[:max_size] || 100
      @max_wait = options[:max_wait] || nil # Future: time-based batching
      @buffer = []
      @mutex = Mutex.new
    end

    # Override execute to buffer items and emit batches via output queue
    def execute(context, input_queue, output_queue, stage_stats)
      loop do
        item = input_queue.pop

        # Handle END signal or AllUpstreamsDone
        break if item.is_a?(AllUpstreamsDone)
        break if item.is_a?(Message) && item.end_of_stream?

        buffer = nil

        @mutex.synchronize do
          @buffer << item

          if @buffer.size >= @max_size
            buffer = @buffer.dup
            @buffer.clear
          end
        end

        next unless buffer && output_queue

        begin
          start_time = Time.now if stage_stats

          if @block
            # Accumulator block receives |batch, output| like other stages
            context.instance_exec(buffer, output_queue, &@block)
          else
            # No block - just pass through
            output_queue << buffer
          end

          # Record per-batch latency
          stage_stats&.record_latency(Time.now - start_time)
        rescue StandardError => e
          # Log batch-level errors but continue processing
          Minigun.logger.error "[Stage:#{name}] Error processing batch: #{e.message}"
          Minigun.logger.debug e.backtrace.join("\n") if Minigun.logger.debug?
        end
      end
    end

    # Called at end of pipeline to flush remaining items
    def flush(context, output_queue)
      buffer = nil

      @mutex.synchronize do
        if @buffer.any?
          buffer = @buffer.dup
          @buffer.clear
        end
      end

      return unless buffer && output_queue

      if @block
        # Accumulator block receives |batch, output| like other stages
        context.instance_exec(buffer, output_queue, &@block)
      else
        # No block - just pass through
        output_queue << buffer
      end
    end
  end

  # Router stages for fan-out patterns
  # Base functionality for all routers
  class RouterStage < Stage
    attr_accessor :targets

    def initialize(name:, targets:)
      super(name: name, options: {})
      @targets = targets
    end

    protected

    def send_end_signals(worker_ctx)
      # Broadcast END to ALL router targets
      @targets.each do |target|
        worker_ctx.stage_input_queues[target] << Message.end_signal(source: worker_ctx.stage_name)
      end
    end
  end

  # Broadcast router - sends each item to ALL downstream stages
  class RouterBroadcastStage < RouterStage
    def run_worker_loop(worker_ctx)
      loop do
        item = worker_ctx.input_queue.pop

        # Handle END signal
        if item.is_a?(Message) && item.end_of_stream?
          worker_ctx.sources_expected << item.source # Discover dynamic source
          worker_ctx.sources_done << item.source
          break if worker_ctx.sources_done == worker_ctx.sources_expected

          next
        end

        # Broadcast to all downstream stages (fan-out semantics)
        @targets.each do |target|
          worker_ctx.stage_input_queues[target] << item
        end
      end
    ensure
      send_end_signals(worker_ctx)
    end
  end

  # Round-robin router - distributes items across downstream stages
  class RouterRoundRobinStage < RouterStage
    def run_worker_loop(worker_ctx)
      target_queues = @targets.map { |target| worker_ctx.stage_input_queues[target] }
      round_robin_index = 0

      loop do
        item = worker_ctx.input_queue.pop

        # Handle END signal
        if item.is_a?(Message) && item.end_of_stream?
          worker_ctx.sources_expected << item.source # Discover dynamic source
          worker_ctx.sources_done << item.source
          break if worker_ctx.sources_done == worker_ctx.sources_expected

          next
        end

        # Round-robin to downstream stages
        target_queues[round_robin_index] << item
        round_robin_index = (round_robin_index + 1) % target_queues.size
      end

      send_end_signals(worker_ctx)
    end
  end

  # Stage that wraps and executes a nested pipeline
  class PipelineStage < Stage
    attr_reader :pipeline, :stages_to_add

    def initialize(name:, options: {})
      super

      # PipelineStage wraps a Pipeline instance for execution
      # We'll inject the pipeline later when we have the config
      @pipeline = nil
      @stages_to_add = [] # Queue of stages to add when pipeline is created
    end

    def run_mode
      :composite # Manages internal stages
    end

    # Execute method for PipelineStage - handles both producer and consumer modes
    def execute(context, input_queue, output_queue, stage_stats)
      return unless @pipeline

      # Producer mode: input_queue is nil, run nested pipeline once and collect outputs
      if input_queue.nil?
        execute_as_producer(context, output_queue)
        return
      end

      # Consumer mode: process items from input_queue through nested pipeline
      loop do
        item = input_queue.pop

        # Handle END signal or AllUpstreamsDone
        break if item.is_a?(AllUpstreamsDone)
        break if item.is_a?(Message) && item.end_of_stream?

        begin
          start_time = Time.now if stage_stats

          # Process item through the pipeline's stages sequentially (in-process, no full pipeline infrastructure)
          current_items = [item]

          @pipeline.stages.each_value do |stage|
            # Only feed to streaming stages
            next unless stage.run_mode == :streaming

            break if current_items.empty?

            next_items = []
            current_items.each do |current_item|
              # Create a temporary output queue for this stage
              stage_output = []
              stage_output.define_singleton_method(:<<) do |i|
                push(i)
                self
              end

              # Create a temporary input queue with just this item
              temp_input = Queue.new
              temp_input << current_item
              temp_input << Message.end_signal(source: :temp)

              # Execute stage with temporary queues (no stats for nested execution)
              stage.execute(context, temp_input, stage_output, stage_stats)

              # Collect outputs
              next_items.concat(stage_output)
            end
            current_items = next_items
          end

          # Output final results to output queue
          current_items.each { |result_item| output_queue << result_item } if output_queue

          # Record per-item latency
          stage_stats&.record_latency(Time.now - start_time)
        rescue StandardError => e
          # Log item-level errors but continue processing
          Minigun.logger.error "[Stage:#{name}] Error processing item through nested pipeline: #{e.message}"
          Minigun.logger.debug e.backtrace.join("\n") if Minigun.logger.debug?
        end
      end
    end

    # Run the worker loop for pipeline stages
    def run_worker_loop(stage_ctx)
      stage_stats = stage_ctx.stage_stats
      stage_stats.start!

      stage_ctx.pipeline.send(:execute_stage_hooks, :before, stage_ctx.stage_name)

      # Create queues (input_queue will be nil for producer mode)
      input_queue = stage_ctx.sources_expected.empty? ? nil : create_input_queue(stage_ctx)
      output_queue = create_output_queue(stage_ctx)

      # Execute via executor (defines HOW: inline/threaded/process)
      # For producer mode, input_queue is nil - execute() detects this and runs as producer
      context = stage_ctx.pipeline.context
      stage_ctx.executor.execute_stage(self, context, input_queue, output_queue, stage_stats)

      stage_ctx.pipeline.send(:execute_stage_hooks, :after, stage_ctx.stage_name)
    ensure
      # Send END signals to all downstream targets
      send_end_signals(stage_ctx)
    end

    # Execute as a producer - run the nested pipeline and collect its outputs
    # Terminal stages automatically drain into :_exit collector added during DAG building
    def execute_as_producer(context, output_queue)
      return unless @pipeline

      # Set output_queues - the pipeline's DAG builder will add :_exit collector for terminal stages
      @pipeline.instance_variable_set(:@output_queues, { output: output_queue }) if output_queue

      # Run the nested pipeline - terminal stages will automatically route to :_exit which forwards to output_queue
      @pipeline.run(context)
    end

    # Set the wrapped pipeline (called by Task)
    def pipeline=(pipeline)
      @pipeline = pipeline

      # Add any queued stages
      @stages_to_add.each do |stage_info|
        @pipeline.add_stage(stage_info[:type], stage_info[:name], stage_info[:options], &stage_info[:block])
      end
      @stages_to_add.clear
    end

    # Add a child stage to this pipeline
    def add_stage(type, name, options = {}, &block)
      if @pipeline
        @pipeline.add_stage(type, name, options, &block)
      else
        # Queue for later when pipeline is set
        @stages_to_add << { type: type, name: name, options: options, block: block }
      end
    end
  end
end
