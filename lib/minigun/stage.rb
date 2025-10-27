# frozen_string_literal: true

module Minigun
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
    #   :consumer = consumer do |item|
    #   :processor = processor do |item, output|
    #   :stage = stage do |input, output|
    def execute(context, item: nil, input_queue: nil, output_queue: nil)
      return unless @block

      case @stage_type
      when :producer
        # Producer: do |output|
        context.instance_exec(output_queue, &@block)
      when :consumer
        # Consumer: do |item|
        context.instance_exec(item, &@block)
      when :processor
        # Processor: do |item, output|
        context.instance_exec(item, output_queue, &@block)
      when :stage
        # Stage with input loop: do |input, output|
        context.instance_exec(input_queue, output_queue, &@block)
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
        # Process the batch with custom logic if provided
        processed_batch = if @block
          context.instance_exec(batch_to_emit, &@block)
        else
          batch_to_emit
        end
        output_queue << processed_batch
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
        processed_batch = if @block
          context.instance_exec(batch_to_emit, &@block)
        else
          batch_to_emit
        end
        output_queue << processed_batch
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
      return unless @pipeline && item

      # Process item through the pipeline's stages sequentially (in-process, no full pipeline infrastructure)
      current_items = [item]

      @pipeline.stages.each_value do |stage|
        # Skip producers - we're feeding items in from upstream
        next if stage.producer? || stage.is_a?(PipelineStage)

        break if current_items.empty?

        next_items = []
        current_items.each do |current_item|
          # Execute stage without emit - just collect returned value
          result = stage.execute(context, item: current_item, output_queue: nil)
          next_items << result if result
        end
        current_items = next_items.flatten
      end

      # Output results to output queue
      current_items.each { |result_item| output_queue << result_item } if output_queue
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
