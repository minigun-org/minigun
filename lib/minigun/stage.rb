# frozen_string_literal: true

module Minigun
  # Context object for stage worker loops
  WorkerContext = Struct.new(
    :input_queue,
    :sources_expected,
    :sources_done,
    :dag,
    :runtime_edges,
    :stage_input_queues,
    :executor,
    :pipeline,
    :stage_name,
    keyword_init: true
  )

  # Base class for all execution units (stages and pipelines)
  # Implements the Composite pattern where Pipeline is a composite Stage
  class Stage
    attr_reader :name, :options

    def initialize(name:, options: {})
      @name = name
      @options = options
    end

    # Execute the stage with the given context and item
    # Returns emitted items for routing (if applicable)
    def execute(context, item = nil)
      raise NotImplementedError, "Subclasses must implement #execute"
    end

    # Run the worker loop for this stage
    # Default implementation for non-router, non-special stages
    def run_worker_loop(worker_ctx)
      raise NotImplementedError, "Subclasses must implement #run_worker_loop"
    end

    # Whether this stage is a producer (no input)
    def producer?
      false
    end

    # Router? - only RouterStage returns true
    def router?
      false
    end

    # Consumer? - default false, overridden by AtomicStage
    def consumer?
      false
    end

    # Processor? - default false, overridden by AtomicStage
    def processor?
      false
    end

    # Stage with input loop? - default false, overridden by AtomicStage
    def stage_with_loop?
      false
    end

    # Whether this stage is composite (contains other stages)
    def composite?
      false
    end

    # Get execution context configuration for this stage
    def execution_context
      @options[:_execution_context]
    end

    # Hash representation (for test compatibility)
    def to_h
      { name: @name, options: @options }
    end

    # Hash-like access (for test compatibility)
    def [](key)
      case key
      when :name then @name
      when :options then @options
      else nil
      end
    end
  end

  # Atomic stages - leaf nodes that execute a single block
  # Behavior is inferred from:
  # - producer?() checks block arity == 0 (runs immediately, no input)
  # - DAG.terminal?(name) checks if it's a consumer (doesn't emit)
  # - Everything else is a processor (transforms items)
  class AtomicStage < Stage
    attr_reader :block, :stage_type

    def initialize(name:, block:, options: {})
      super(name: name, options: options)
      @block = block
      @stage_type = options[:stage_type] || :processor  # Default to processor
    end

    # Producer? - determined by DSL method used
    def producer?
      @stage_type == :producer
    end

    # Consumer? - terminal stage with no output
    def consumer?
      @stage_type == :consumer
    end

    # Processor? - transforms items
    def processor?
      @stage_type == :processor
    end

    # Stage with input loop?
    def stage_with_loop?
      @stage_type == :stage
    end

    # Execute stage logic with queue-based arguments
    # Stage type determines arguments:
    #   :producer = producer do |output|
    #   :consumer = consumer do |item, output|  (processor is alias for consumer)
    #   :stage = stage do |input, output|
    def execute(context, item: nil, input_queue: nil, output_queue: nil)
      return unless @block

      case @stage_type
      when :producer
        # Producer: do |output|
        context.instance_exec(output_queue, &@block)
      when :consumer, :processor
        # Consumer/Processor: do |item, output|
        # Whether they use output or not is up to the stage implementation
        context.instance_exec(item, output_queue, &@block)
      when :stage
        # Stage with input loop: do |input, output|
        context.instance_exec(input_queue, output_queue, &@block)
      end
    end

    # Run the worker loop for atomic stages (processors/consumers)
    def run_worker_loop(worker_ctx)
      require_relative 'queue_wrappers'

      # Create wrapped queues for the new DSL
      wrapped_input = InputQueue.new(worker_ctx.input_queue, worker_ctx.stage_name, worker_ctx.sources_expected)
      wrapped_output = OutputQueue.new(
        worker_ctx.stage_name,
        worker_ctx.dag.downstream(worker_ctx.stage_name).map { |ds| worker_ctx.stage_input_queues[ds] },
        worker_ctx.stage_input_queues,
        worker_ctx.runtime_edges
      )

      # If stage has input loop, pass both queues and let it manage its own loop
      if stage_with_loop?
        execute_with_queues(worker_ctx, wrapped_input, wrapped_output)
        flush_if_needed(worker_ctx, wrapped_output)
        send_end_signals(worker_ctx)
      else
        # Traditional item-by-item processing
        process_items(worker_ctx, wrapped_output)
        flush_if_needed(worker_ctx, wrapped_output)
        send_end_signals(worker_ctx)
      end
    end

    # Hash representation (for test compatibility)
    def to_h
      super.merge(block: @block, stage_type: @stage_type)
    end

    # Hash-like access (for test compatibility)
    def [](key)
      case key
      when :block then @block
      when :stage_type then @stage_type
      else super
      end
    end

    private

    def execute_with_queues(worker_ctx, wrapped_input, wrapped_output)
      context = worker_ctx.pipeline.instance_variable_get(:@context)
      execute(context, input_queue: wrapped_input, output_queue: wrapped_output)
    end

    def process_items(worker_ctx, wrapped_output)
      loop do
        msg = worker_ctx.input_queue.pop

        # Handle END signal
        if msg.is_a?(Message) && msg.end_of_stream?
          worker_ctx.sources_expected << msg.source  # Discover dynamic source
          worker_ctx.sources_done << msg.source
          break if worker_ctx.sources_done == worker_ctx.sources_expected
          next
        end

        # Execute the stage with queue wrappers (stages push to output directly)
        execute_item(worker_ctx, msg, wrapped_output)
      end
    end

    def execute_item(worker_ctx, item, wrapped_output)
      context = worker_ctx.pipeline.instance_variable_get(:@context)
      stats = worker_ctx.pipeline.instance_variable_get(:@stats)

      worker_ctx.executor.execute_stage_item(
        stage: self,
        item: item,
        user_context: context,
        input_queue: nil,
        output_queue: wrapped_output,
        stats: stats,
        pipeline: worker_ctx.pipeline
      )
    end

    def flush_if_needed(worker_ctx, wrapped_output)
      return unless respond_to?(:flush)

      context = worker_ctx.pipeline.instance_variable_get(:@context)
      flush(context, wrapped_output)
    end

    def send_end_signals(worker_ctx)
      dag_downstream = worker_ctx.dag.downstream(worker_ctx.stage_name)
      dynamic_targets = worker_ctx.runtime_edges[worker_ctx.stage_name].to_a
      all_targets = (dag_downstream + dynamic_targets).uniq

      all_targets.each do |target|
        # Skip if target doesn't have an input queue (e.g., producers)
        next unless worker_ctx.stage_input_queues[target]

        worker_ctx.stage_input_queues[target] << Message.end_signal(source: worker_ctx.stage_name)
      end
    end
  end

  # Accumulator stage - batches items before passing to consumer
  # Collects N items, then emits them as a batch
  class AccumulatorStage < AtomicStage
    attr_reader :max_size, :max_wait

    def initialize(name:, block: nil, options: {})
      super
      @max_size = options[:max_size] || 100
      @max_wait = options[:max_wait] || nil  # Future: time-based batching
      @buffer = []
      @mutex = Mutex.new
    end

    # Override execute to buffer items and emit batches via output queue
    def execute(context, item: nil, input_queue: nil, output_queue: nil)
      return unless item

      batch_to_emit = nil

      @mutex.synchronize do
        @buffer << item

        if @buffer.size >= @max_size
          batch_to_emit = @buffer.dup
          @buffer.clear
        end
      end

      if batch_to_emit && output_queue
        if @block
          # Accumulator block receives |batch, output| like other stages
          context.instance_exec(batch_to_emit, output_queue, &@block)
        else
          # No block - just pass through
          output_queue << batch_to_emit
        end
      end
    end

    # Called at end of pipeline to flush remaining items
    def flush(context, output_queue)
      batch_to_emit = nil

      @mutex.synchronize do
        if @buffer.any?
          batch_to_emit = @buffer.dup
          @buffer.clear
        end
      end

      if batch_to_emit && output_queue
        if @block
          # Accumulator block receives |batch, output| like other stages
          context.instance_exec(batch_to_emit, output_queue, &@block)
        else
          # No block - just pass through
          output_queue << batch_to_emit
        end
      end
    end
  end

  # Pipeline stage - composite stage that wraps a Pipeline
  # This is the key to the composite pattern!
  # Router stage for fan-out (broadcast or round-robin)
  class RouterStage < Stage
    attr_accessor :targets, :routing_strategy

    def initialize(name:, targets:, routing_strategy: :broadcast)
      super(name: name, options: {})
      @targets = targets
      @routing_strategy = routing_strategy  # :broadcast or :round_robin
    end

    def router?
      true
    end

    def broadcast?
      @routing_strategy == :broadcast
    end

    def round_robin?
      @routing_strategy == :round_robin
    end

    def execute(context, item)
      # Router doesn't transform, just passes through
      [item]
    end

    # Run the worker loop for router stages
    def run_worker_loop(worker_ctx)
      target_queues = @targets.map { |target| worker_ctx.stage_input_queues[target] }

      if round_robin?
        run_round_robin_loop(worker_ctx, target_queues)
      else
        run_broadcast_loop(worker_ctx, target_queues)
      end

      # Broadcast END to ALL router targets (even for round-robin)
      @targets.each do |target|
        worker_ctx.stage_input_queues[target] << Message.end_signal(source: worker_ctx.stage_name)
      end
    end

    private

    def run_round_robin_loop(worker_ctx, target_queues)
      round_robin_index = 0

      loop do
        msg = worker_ctx.input_queue.pop

        # Handle END signal
        if msg.is_a?(Message) && msg.end_of_stream?
          worker_ctx.sources_expected << msg.source  # Discover dynamic source
          worker_ctx.sources_done << msg.source
          break if worker_ctx.sources_done == worker_ctx.sources_expected
          next
        end

        # Round-robin to downstream stages
        target_queues[round_robin_index] << msg
        round_robin_index = (round_robin_index + 1) % target_queues.size
      end
    end

    def run_broadcast_loop(worker_ctx, target_queues)
      loop do
        msg = worker_ctx.input_queue.pop

        # Handle END signal
        if msg.is_a?(Message) && msg.end_of_stream?
          worker_ctx.sources_expected << msg.source  # Discover dynamic source
          worker_ctx.sources_done << msg.source
          break if worker_ctx.sources_done == worker_ctx.sources_expected
          next
        end

        # Broadcast to all downstream stages (fan-out semantics)
        @targets.each do |target|
          worker_ctx.stage_input_queues[target] << msg
        end
      end
    end
  end

  class PipelineStage < Stage
    attr_reader :pipeline

    def initialize(name:, options: {})
      super(name: name, options: options)

      # PipelineStage wraps a Pipeline instance for execution
      # We'll inject the pipeline later when we have the config
      @pipeline = nil
      @stages_to_add = []  # Queue of stages to add when pipeline is created
    end

    def composite?
      true
    end

    # Execute method for when PipelineStage is used as a processor/consumer
    def execute(context, item: nil, input_queue: nil, output_queue: nil)
      # If no pipeline set, just pass item through
      unless @pipeline
        output_queue << item if output_queue && item
        return
      end

      # If used as producer (no item), run the nested pipeline and collect outputs
      if item.nil?
        execute_as_producer(context, output_queue)
        return
      end

      # Process item through the pipeline's stages sequentially (in-process, no full pipeline infrastructure)
      current_items = [item]

      @pipeline.stages.each_value do |stage|
        # Skip producers - we're feeding items in from upstream
        next if stage.producer? || stage.is_a?(PipelineStage)

        break if current_items.empty?

        next_items = []
        current_items.each do |current_item|
          # Create a temporary output queue for this stage
          stage_output = []
          stage_output.define_singleton_method(:<<) { |i| push(i); self }

          # Execute stage with temporary output queue
          stage.execute(context, item: current_item, output_queue: stage_output)

          # Collect outputs
          next_items.concat(stage_output)
        end
        current_items = next_items
      end

      # Output final results to output queue
      current_items.each { |result_item| output_queue << result_item } if output_queue
    end

    # Run the worker loop for pipeline stages (delegate to AtomicStage logic)
    def run_worker_loop(worker_ctx)
      require_relative 'queue_wrappers'

      # Create wrapped queues for the new DSL
      wrapped_input = InputQueue.new(worker_ctx.input_queue, worker_ctx.stage_name, worker_ctx.sources_expected)
      wrapped_output = OutputQueue.new(
        worker_ctx.stage_name,
        worker_ctx.dag.downstream(worker_ctx.stage_name).map { |ds| worker_ctx.stage_input_queues[ds] },
        worker_ctx.stage_input_queues,
        worker_ctx.runtime_edges
      )

      # Traditional item-by-item processing
      loop do
        msg = worker_ctx.input_queue.pop

        # Handle END signal
        if msg.is_a?(Message) && msg.end_of_stream?
          worker_ctx.sources_expected << msg.source  # Discover dynamic source
          worker_ctx.sources_done << msg.source
          break if worker_ctx.sources_done == worker_ctx.sources_expected
          next
        end

        # Execute the stage with queue wrappers
        context = worker_ctx.pipeline.instance_variable_get(:@context)
        stats = worker_ctx.pipeline.instance_variable_get(:@stats)

        worker_ctx.executor.execute_stage_item(
          stage: self,
          item: msg,
          user_context: context,
          input_queue: nil,
          output_queue: wrapped_output,
          stats: stats,
          pipeline: worker_ctx.pipeline
        )
      end

      # Send END signals
      dag_downstream = worker_ctx.dag.downstream(worker_ctx.stage_name)
      dynamic_targets = worker_ctx.runtime_edges[worker_ctx.stage_name].to_a
      all_targets = (dag_downstream + dynamic_targets).uniq

      all_targets.each do |target|
        # Skip if target doesn't have an input queue (e.g., producers)
        next unless worker_ctx.stage_input_queues[target]

        worker_ctx.stage_input_queues[target] << Message.end_signal(source: worker_ctx.stage_name)
      end
    end

    # Execute as a producer - run the nested pipeline and collect its outputs
    def execute_as_producer(context, output_queue)
      # Collect all items produced by the nested pipeline
      collected_items = []

      # Add a temporary consumer to collect items
      temp_consumer_added = false
      unless @pipeline.stages.values.any? { |s| s.consumer? && s.name.to_s.start_with?('_temp_collector') }
        @pipeline.instance_eval do
          add_stage(:stage, :_temp_collector, stage_type: :consumer) do |item, output|
            collected_items << item
          end
        end
        temp_consumer_added = true
      end

      # Run the nested pipeline
      @pipeline.run(context)

      # Send collected items to parent output queue
      collected_items.each { |item| output_queue << item } if output_queue

      # Clean up temporary collector
      if temp_consumer_added
        @pipeline.stages.delete(:_temp_collector)
      end
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
