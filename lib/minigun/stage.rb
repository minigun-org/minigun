# frozen_string_literal: true

require 'securerandom'

module Minigun
  # Unified context for all stage execution (producers and workers)
  StageContext = Struct.new(
    # Common to all stages
    :stage,
    :dag,
    :runtime_edges,
    :stage_stats,
    # Worker-specific (nil/empty for producers)
    :worker,
    :input_queue,
    :sources_expected,
    :sources_done,
    keyword_init: true
  ) do
    # Convenience method to access executor through worker
    def executor
      worker&.executor
    end

    # Convenience method for stage name (delegates to stage object)
    def stage_name
      stage&.name
    end

    def pipeline
      stage&.pipeline
    end

    def root_pipeline
      pipeline&.root_pipeline
    end
  end

  # Base class for all execution units (stages and pipelines)
  # Implements the Composite pattern where Pipeline is a composite Stage
  # Also handles loop-based stages (stages that manage their own input loop)
  class Stage
    attr_reader :pipeline, :name, :options, :block

    # Positional constructor: Stage.new(name, pipeline, block, options)
    def initialize(name, pipeline, block = nil, options = {})
      @name = name
      @pipeline = pipeline
      @block = block
      @options = options
      @shutdown_requested = false

      # Auto-generate name if not provided (for unnamed stages)
      # Use "_" prefix + 8 char random hex
      # TODO: Convert to base62
      @name = :"_#{SecureRandom.hex(4)}" if @name.nil?

      # Register stage with the task's stage_registry (if available)
      task&.stage_registry&.register(@pipeline, self)
    end

    # Request graceful shutdown of this stage
    def request_shutdown
      @shutdown_requested = true
    end

    # Check if shutdown has been requested (for use in loops)
    def shutdown_requested?
      @shutdown_requested ||= @pipeline&.shutdown_requested?
    end

    # Raise ShutdownRequested if shutdown has been requested
    # Call this periodically in long-running operations
    def check_shutdown!
      raise Errors::ShutdownRequested if shutdown_requested?
    end

    def task
      @pipeline.task
    end

    def root_pipeline
      @pipeline.root_pipeline
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

    # --- Demand configuration ---

    # Get demand mode for this stage
    # @return [Symbol] :auto, :manual, or :disabled
    def demand_mode
      @options[:demand_mode] || :auto
    end

    # Get min_demand threshold for this stage
    # @return [Integer]
    def min_demand
      @options[:min_demand] || Minigun.default_min_demand
    end

    # Get max_demand limit for this stage
    # @return [Integer]
    def max_demand
      @options[:max_demand] || Minigun.default_max_demand
    end

    # Get demand timeout for this stage
    # @return [Float, nil]
    def demand_timeout
      @options[:demand_timeout] || Minigun.demand_timeout
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

    # Run the stage execution
    # Loop-based stages manage their own input loop
    def run_stage(stage_ctx)
      # Create wrapped queues
      input_queue = create_input_queue(stage_ctx) # TODO: move to worker?
      output_queue = create_output_queue(stage_ctx)

      # Execute with both queues (block manages its own loop)
      context = stage_ctx.root_pipeline.context
      execute(context, input_queue, output_queue, stage_ctx.stage_stats)
    ensure
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

    def to_s
      "#{self.class.name}(#{name})"
    end

    def inspect
      to_s
    end

    # Call the stage's #call method with appropriate args based on arity
    # Executors call this from outside the class for callable stages
    def call_with_arity(*args, &)
      arity = method(:call).arity.abs
      call(*args[...arity], &)
    end

    private

    # Create wrapped input queue for this stage
    def create_input_queue(stage_ctx)
      pipeline = stage_ctx.stage.pipeline

      # Use demand-aware queue if demand is enabled
      if pipeline&.demand_enabled? && pipeline.demand_registry
        demand_channels = pipeline.demand_registry.channels_to_consumer(stage_ctx.stage)

        queue = Demand::AwareInputQueue.new(
          stage_ctx.input_queue,
          stage_ctx.stage,
          stage_ctx.sources_expected,
          stage_stats: stage_ctx.stage_stats,
          demand_channels: demand_channels
        )

        # Initialize demand on startup
        queue.initialize_demand
        queue
      else
        InputQueue.new(
          stage_ctx.input_queue,
          stage_ctx.stage,
          stage_ctx.sources_expected,
          stage_stats: stage_ctx.stage_stats
        )
      end
    end

    # Create wrapped output queue for this stage
    def create_output_queue(stage_ctx)
      # DAG and queues now use Stage objects
      downstream = stage_ctx.dag.downstream(stage_ctx.stage)
      task = stage_ctx.stage.task
      downstream_queues = downstream.filter_map { |ds| task&.find_queue(ds) }
      pipeline = stage_ctx.stage.pipeline

      # Use demand-aware queue if demand is enabled
      if pipeline&.demand_enabled? && pipeline.demand_registry
        demand_channels = pipeline.demand_registry.channels_from_producer(stage_ctx.stage)

        Demand::AwareOutputQueue.new(
          stage_ctx.stage,
          downstream_queues,
          stage_ctx.runtime_edges,
          stage_stats: stage_ctx.stage_stats,
          demand_channels: demand_channels,
          demand_mode: stage_ctx.stage.demand_mode,
          demand_timeout: stage_ctx.stage.demand_timeout
        )
      else
        OutputQueue.new(
          stage_ctx.stage,
          downstream_queues,
          stage_ctx.runtime_edges,
          stage_stats: stage_ctx.stage_stats
        )
      end
    end

    # Consolidated end signal logic used by all stage types
    def send_end_signals(stage_ctx)
      dag_downstream = stage_ctx.dag.downstream(stage_ctx.stage)
      dynamic_targets = stage_ctx.runtime_edges[stage_ctx.stage].to_a
      all_targets = (dag_downstream + dynamic_targets).uniq
      task = stage_ctx.stage.task

      all_targets.each do |target|
        queue = task.find_queue(target)
        next unless queue

        queue << EndOfSource.new(stage_ctx.stage)
      end
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

    def run_stage(stage_ctx)
      # Execute before hooks
      execute_hooks(stage_ctx, :before)

      # Create output queue
      output_queue = create_output_queue(stage_ctx)

      # Execute producer block directly (ProducerStage doesn't use executor since it's autonomous)
      context = stage_ctx.root_pipeline.context
      execute(context, nil, output_queue, stage_ctx.stage_stats)

      # Execute after hooks
      execute_hooks(stage_ctx, :after)
    ensure
      send_end_signals(stage_ctx)
    end

    private

    def execute_hooks(ctx, type)
      ctx.root_pipeline.execute_stage_hooks(type, ctx.stage)
    end
  end

  # Enumerator-based producer stage - iterates over a source
  # Source can be: enumerable, proc/lambda, or method symbol
  class EnumeratorProducerStage < ProducerStage
    attr_reader :source

    def initialize(name, pipeline, source, _block = nil, options = {})
      super(name, pipeline, nil, options)
      @source = source
    end

    def execute(context, _input_queue, output_queue, _stage_stats)
      enumerable = resolve_source(context)
      enumerable.each do |item|
        # Check for shutdown before processing each item
        check_shutdown!
        output_queue << item
      end
    end

    private

    def resolve_source(context)
      case @source
      when Symbol
        context.send(@source)
      when Proc
        @source.call
      else
        @source
      end
    end
  end

  # Consumer/Processor stage - loops on input, processes items
  class ConsumerStage < Stage
    def execute(context, input_queue, output_queue, stage_stats)
      # Consumer stages pop from input_queue and process items
      loop do
        item = input_queue.pop

        # Just break from the loop - the worker_loop will handle signaling completion
        break if item.is_a?(EndOfStage)

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
        rescue Errors::ShutdownRequested
          # Re-raise shutdown to exit the loop
          raise
        rescue StandardError => e
          # Log item-level errors but continue processing
          Minigun.logger.error "[Stage:#{name}] Error processing item: #{e.message}"
          Minigun.logger.debug e.backtrace.join("\n") if Minigun.logger.debug?
        end
      end
    end

    def run_stage(stage_ctx)
      # Execute before hooks
      stage_ctx.root_pipeline.send(:execute_stage_hooks, :before, stage_ctx.stage)

      # Create wrapped queues
      input_queue = create_input_queue(stage_ctx)
      output_queue = create_output_queue(stage_ctx)

      # Execute via executor (defines HOW: inline/threaded/process)
      context = stage_ctx.root_pipeline.context
      stage_ctx.executor.execute_stage(self, context, input_queue, output_queue)

      # Execute after hooks
      stage_ctx.root_pipeline.send(:execute_stage_hooks, :after, stage_ctx.stage)

      # Flush and cleanup
      flush_if_needed(stage_ctx, output_queue)
    ensure
      send_end_signals(stage_ctx)
    end

    private

    def flush_if_needed(stage_ctx, output_queue)
      return unless respond_to?(:flush)

      context = stage_ctx.root_pipeline.context
      flush(context, output_queue)
    end
  end

  # Batch stage - batches items before passing to consumer
  # Collects N items or waits max_wait seconds, then emits them as a batch
  #
  # @param max_size [Integer] Maximum items per batch (default: 100)
  # @param max_wait [Float, nil] Maximum seconds to wait before flushing (nil = no time limit)
  #
  # Examples:
  #   batch(10)                                # Batch by size only
  #   batch(:batcher, max_size: 50)            # Named batch, size only
  #   batch(:batcher, max_wait: 5.0)           # Batch by time only (100 item default)
  #   batch(:batcher, max_size: 50, max_wait: 2.0)  # Batch by size OR time
  class BatchStage < ConsumerStage
    attr_reader :max_size, :max_wait

    # Positional constructor: BatchStage.new(name, pipeline, block, options)
    def initialize(name, pipeline, block, options = {})
      super

      @max_size = options[:max_size] || 100
      @max_wait = options[:max_wait] || nil
      @buffer = []
      @mutex = Mutex.new
      @last_flush_time = nil
      @timer_thread = nil
    end

    # Override execute to buffer items and emit batches via output queue
    # When max_wait is set, uses time-based flushing in addition to size-based
    def execute(context, input_queue, output_queue, stage_stats)
      @last_flush_time = Time.now

      if @max_wait
        execute_with_timeout(context, input_queue, output_queue, stage_stats)
      else
        execute_size_only(context, input_queue, output_queue, stage_stats)
      end
    end

    # Called at end of pipeline to flush remaining items
    def flush(context, output_queue)
      buffer = nil

      @mutex.synchronize do
        unless @buffer.empty?
          buffer = @buffer.dup
          @buffer.clear
        end
      end

      return unless buffer && output_queue

      emit_batch(context, buffer, output_queue, nil)
    end

    private

    # Size-only batching (original behavior) - blocks on pop
    def execute_size_only(context, input_queue, output_queue, stage_stats)
      loop do
        item = input_queue.pop

        break if item.is_a?(EndOfStage)

        buffer = nil

        @mutex.synchronize do
          @buffer << item

          if @buffer.size >= @max_size
            buffer = @buffer.dup
            @buffer.clear
          end
        end

        emit_batch(context, buffer, output_queue, stage_stats) if buffer && output_queue
      end
    end

    # Time-based batching - uses timer thread to trigger flushes
    def execute_with_timeout(context, input_queue, output_queue, stage_stats)
      start_timer_thread(context, output_queue, stage_stats)

      begin
        loop do
          item = input_queue.pop

          break if item.is_a?(EndOfStage)

          buffer = nil

          @mutex.synchronize do
            @buffer << item

            # Flush if size threshold reached
            if @buffer.size >= @max_size
              buffer = @buffer.dup
              @buffer.clear
              @last_flush_time = Time.now
            end
          end

          emit_batch(context, buffer, output_queue, stage_stats) if buffer && output_queue
        end
      ensure
        stop_timer_thread
      end
    end

    # Background thread that triggers time-based flushes
    def start_timer_thread(context, output_queue, stage_stats)
      @timer_thread = Thread.new do
        loop do
          # Sleep for a fraction of max_wait to check more frequently
          sleep(@max_wait / 4.0)

          buffer = nil

          @mutex.synchronize do
            # Check if enough time has passed and buffer has items
            next if @buffer.empty?
            next if (Time.now - @last_flush_time) < @max_wait

            buffer = @buffer.dup
            @buffer.clear
            @last_flush_time = Time.now
          end

          emit_batch(context, buffer, output_queue, stage_stats) if buffer && output_queue
        end
      rescue StandardError => e
        Minigun.logger.error "[Stage:#{name}] Timer thread error: #{e.message}"
        Minigun.logger.debug e.backtrace.join("\n") if Minigun.logger.debug?
      end
    end

    def stop_timer_thread
      return unless @timer_thread

      @timer_thread.kill
      @timer_thread.join(0.5) # Wait briefly for cleanup
      @timer_thread = nil
    end

    # Emit a batch with proper error handling and stats tracking
    def emit_batch(context, buffer, output_queue, stage_stats)
      return unless buffer && !buffer.empty?

      begin
        start_time = Time.now if stage_stats

        if @block
          # Batch block receives |batch, output| like other stages
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

  # Debatch stage - unpacks incoming batches into individual items
  # Receives items that respond to #each and emits each element individually
  class DebatchStage < ConsumerStage
    def execute(_context, input_queue, output_queue, stage_stats)
      loop do
        item = input_queue.pop
        break if item.is_a?(EndOfStage)

        begin
          start_time = Time.now if stage_stats

          if item.respond_to?(:each)
            item.each { |element| output_queue << element }
          else
            output_queue << item
          end

          stage_stats&.record_latency(Time.now - start_time)
        rescue StandardError => e
          Minigun.logger.error "[Stage:#{name}] Error debatching: #{e.message}"
          Minigun.logger.debug e.backtrace.join("\n") if Minigun.logger.debug?
        end
      end
    end
  end

  # Rebatch stage - re-batches incoming batches into new batch sizes
  # Receives items that respond to #each and emits new batches of specified size
  class RebatchStage < ConsumerStage
    attr_reader :batch_size

    def initialize(name, pipeline, block = nil, options = {})
      super
      @batch_size = options[:_rebatch_size] || 100
      @buffer = []
      @mutex = Mutex.new
    end

    def execute(_context, input_queue, output_queue, stage_stats)
      loop do
        item = input_queue.pop
        break if item.is_a?(EndOfStage)

        begin
          start_time = Time.now if stage_stats
          buffer_item(item, output_queue)
          stage_stats&.record_latency(Time.now - start_time)
        rescue StandardError => e
          Minigun.logger.error "[Stage:#{name}] Error processing batch: #{e.message}"
          Minigun.logger.debug e.backtrace.join("\n") if Minigun.logger.debug?
        end
      end
    end

    def flush(_context, output_queue)
      buffer = nil

      @mutex.synchronize do
        unless @buffer.empty?
          buffer = @buffer.dup
          @buffer.clear
        end
      end

      return unless buffer && output_queue

      output_queue << buffer
    end

    private

    def buffer_item(item, output_queue)
      items = item.respond_to?(:each) ? item.to_a : [item]
      items.each { |element| add_to_buffer(element, output_queue) }
    end

    def add_to_buffer(element, output_queue)
      @mutex.synchronize do
        @buffer << element
        return unless @buffer.size >= @batch_size

        output_queue << @buffer.dup
        @buffer.clear
      end
    end
  end

  # Router stages for fan-out patterns
  # Base class implements Template Method pattern - subclasses only override route_item
  class RouterStage < Stage
    attr_accessor :targets

    # Positional constructor: RouterStage.new(name, pipeline, targets, options)
    def initialize(name, pipeline, targets, options = {})
      super(name, pipeline, nil, options)
      @targets = targets || []
    end

    # Template method - common routing loop for all router types
    def run_stage(worker_ctx)
      setup_routing(worker_ctx)

      loop do
        item = worker_ctx.input_queue.pop

        # Common: Handle EndOfSource signals
        if item.is_a?(EndOfSource)
          worker_ctx.sources_expected << item.stage
          worker_ctx.sources_done << item.stage
          break if worker_ctx.sources_done == worker_ctx.sources_expected

          next
        end

        # Common: Handle RoutedItem from IPC dynamic routing
        if item.is_a?(Minigun::RoutedItem)
          handle_routed_item(worker_ctx, item)
          next
        end

        # Subclass-specific routing logic
        route_item(worker_ctx, item)
      end
    ensure
      send_end_signals(worker_ctx)
    end

    protected

    # Override in subclasses to initialize routing state
    def setup_routing(worker_ctx); end

    # Override in subclasses to implement routing logic
    def route_item(_worker_ctx, _item)
      raise NotImplementedError.new("#{self.class} must implement #route_item")
    end

    def handle_routed_item(worker_ctx, routed_item)
      target = @targets.find { |t| t.name == routed_item.target_stage }
      if target
        queue = worker_ctx.stage.task&.find_queue(target)
        queue&.<< routed_item.item
      else
        router_name = self.class.name.split('::').last.sub('Stage', '')
        Minigun.logger.warn "[#{router_name}] Unknown routed target: #{routed_item.target_stage}"
      end
    end

    def send_end_signals(worker_ctx)
      task = worker_ctx.stage.task
      @targets.each do |target|
        queue = task&.find_queue(target)
        queue&.<< EndOfSource.new(worker_ctx.stage)
      end
    end
  end

  # Broadcast router - sends each item to ALL downstream stages
  class RouterBroadcastStage < RouterStage
    protected

    def route_item(worker_ctx, item)
      task = worker_ctx.stage.task
      @targets.each do |target|
        queue = task&.find_queue(target)
        queue&.<< item
      end
    end
  end

  # Round-robin router - distributes items across downstream stages
  class RouterRoundRobinStage < RouterStage
    protected

    def setup_routing(worker_ctx)
      task = worker_ctx.stage.task
      @target_queues = @targets.filter_map { |target| task&.find_queue(target) }
      @round_robin_index = 0
    end

    def route_item(_worker_ctx, item)
      @target_queues[@round_robin_index] << item
      @round_robin_index = (@round_robin_index + 1) % @target_queues.size
    end
  end

  # Demand-based router - routes items to consumer with highest demand/capacity
  # Inspired by GenStage.DemandDispatcher
  class RouterDemandStage < RouterStage
    def initialize(name, pipeline, targets, options = {})
      super
      @shuffle_on_first = options[:shuffle_on_first_dispatch] || false
      @first_dispatch = true
      @round_robin_index = 0
    end

    protected

    def setup_routing(worker_ctx)
      task = worker_ctx.stage.task
      @target_info = @targets.map { |t| [t, task&.find_queue(t)] }
      @demand_registry = @pipeline.demand_enabled? ? @pipeline.demand_registry : nil

      # Shuffle on first dispatch to avoid overloading first consumer
      return unless @shuffle_on_first && @first_dispatch

      @target_info.shuffle!
      @first_dispatch = false
    end

    def route_item(_worker_ctx, item)
      best_queue = find_best_target
      best_queue << item
    end

    private

    def find_best_target
      # Strategy 1: Use demand system if enabled
      if @demand_registry
        _best_target, best_queue = @target_info.max_by do |target, _queue|
          channel = @demand_registry.channel_for(self, target)
          channel&.pending_demand || 0
        end
        return best_queue if best_queue
      end

      # Strategy 2: Use queue capacity for SizedQueue
      sized = @target_info.select { |_, q| q.is_a?(SizedQueue) }
      if sized.any?
        _, best = sized.max_by { |_, q| q.max - q.size }
        return best
      end

      # Strategy 3: Round-robin for unbounded queues
      _, queue = @target_info[@round_robin_index % @target_info.size]
      @round_robin_index += 1
      queue
    end
  end

  # Partition-based router - routes items based on hash function for partition affinity
  # Inspired by GenStage.PartitionDispatcher
  class RouterPartitionStage < RouterStage
    def initialize(name, pipeline, targets, options = {})
      super
      @partition_count = targets.size
      @hash_fn = build_hash_function(options)
    end

    protected

    def setup_routing(worker_ctx)
      task = worker_ctx.stage.task
      @target_queues = @targets.map { |t| task&.find_queue(t) }
    end

    def route_item(_worker_ctx, item)
      partition = @hash_fn.call(item)
      return if partition == :none # Discard item (like GenStage)

      @target_queues[partition % @partition_count] << item
    end

    private

    def build_hash_function(options)
      partition_key = options[:partition_key]
      custom_hash = options[:hash]

      if custom_hash
        # Custom hash function: ->(item) { partition_index } or :none
        custom_hash
      elsif partition_key.is_a?(Proc)
        # Extract key via proc, then hash
        ->(item) { partition_key.call(item).hash.abs }
      elsif partition_key.is_a?(Symbol)
        # Extract key from hash/object, then hash
        lambda do |item|
          key = item.is_a?(Hash) ? item[partition_key] : item.send(partition_key)
          key.hash.abs
        end
      else
        # Default: hash the entire item
        ->(item) { item.hash.abs }
      end
    end
  end

  # Special exit stage for nested pipelines
  # Automatically created when a pipeline has output to parent
  class ExitStage < ConsumerStage
    # Positional constructor: ExitStage.new(name, pipeline, block, options)
    def initialize(name, pipeline, block, options = {})
      super
    end
  end

  # Stage that wraps and executes a nested pipeline
  class PipelineStage < Stage
    attr_reader :nested_pipeline

    # Positional constructor: PipelineStage.new(name, pipeline, nested_pipeline, options)
    def initialize(name, pipeline, nested_pipeline, options = {})
      super(name, pipeline, nil, options)
      @nested_pipeline = nested_pipeline
    end

    def run_mode
      :composite # Manages internal stages
    end

    # Run the nested pipeline when this stage is executed as a worker
    def run_stage(stage_ctx)
      return unless @nested_pipeline

      # Set up input/output queues for the nested pipeline
      # Pass the PipelineStage's input queue to nested pipeline so entry stages can use it
      unless stage_ctx.sources_expected.empty?
        # Has upstream: pass input queue to nested pipeline
        # The nested pipeline will handle distributing to its entry stages
        @nested_pipeline.instance_variable_set(
          :@input_queues,
          {
            input: stage_ctx.input_queue,
            sources_expected: stage_ctx.sources_expected
          }
        )
      end

      # Always set output queue so pipeline creates :_exit
      @nested_pipeline.instance_variable_set(:@output_queues, { output: create_output_queue(stage_ctx) })

      # Run the nested pipeline (it will handle input distribution to entry stages)
      @nested_pipeline.run(stage_ctx.root_pipeline.context)
    ensure
      send_end_signals(stage_ctx)
    end
  end
end
