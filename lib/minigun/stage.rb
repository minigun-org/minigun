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

    # Whether this stage is an accumulator (batches items)
    def accumulator?
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

    # Convert to hash (for backward compatibility)
    def to_h
      { name: @name, options: @options }
    end

    # Allow hash-like access for backward compatibility
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
    attr_reader :block

    def initialize(name:, block:, options: {})
      super(name: name, options: options)
      @block = block
    end

    # Producer? - no block argument
    def producer?
      @block && (@block.arity == 0 || @block.arity == -1)
    end

    # Execute stage logic
    def execute(context, item = nil)
      return unless @block

      if producer?
        # Producer - no item argument
        context.instance_eval(&@block)
      else
        # Processor/Consumer - has item argument
        context.instance_exec(item, &@block)
      end
    end

    # Execute and return emitted items (for non-terminal stages)
    def execute_with_emit(context, item)
      emitted_items = []
      emit_proc = proc { |i| emitted_items << i }
      context.define_singleton_method(:emit, &emit_proc)

      execute(context, item)

      emitted_items
    end

    # For backward compatibility
    def to_h
      super.merge(block: @block)
    end

    def [](key)
      return @block if key == :block
      super
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

    def accumulator?
      true
    end

    # Process items one at a time, buffering internally
    # Returns an array (with batch) if buffer is full, empty array otherwise
    def execute_with_emit(context, item)
      batch_to_emit = nil

      @mutex.synchronize do
        @buffer << item

        if @buffer.size >= @max_size
          batch_to_emit = @buffer.dup
          @buffer.clear
        end
      end

      if batch_to_emit
        # Process the batch with custom logic if provided
        processed_batch = if @block
          context.instance_exec(batch_to_emit, &@block)
        else
          batch_to_emit
        end
        [processed_batch]
      else
        []
      end
    end

    # Called at end of pipeline to flush remaining items
    def flush(context)
      batch_to_emit = nil

      @mutex.synchronize do
        if @buffer.any?
          batch_to_emit = @buffer.dup
          @buffer.clear
        end
      end

      if batch_to_emit
        processed_batch = if @block
          context.instance_exec(batch_to_emit, &@block)
        else
          batch_to_emit
        end
        [processed_batch]
      else
        []
      end
    end
  end

  # Pipeline stage - composite stage that wraps a Pipeline
  # This is the key to the composite pattern!
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

    # Execute method for when PipelineStage is used as a consumer
    def execute(context, item)
      execute_with_emit(context, item)
      nil  # Consumers don't return values
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

    # Execute this pipeline stage (processes an item through the nested pipeline)
    def execute_with_emit(context, item)
      return [item] unless @pipeline

      # Process item through the pipeline's stages sequentially (in-process, no full pipeline infrastructure)
      # This is for PipelineStages used as processors/consumers in a DAG
      current_items = [item]

      @pipeline.stages.each_value do |stage|
        # Skip producers - we're feeding items in from upstream
        next if stage.producer? || stage.is_a?(PipelineStage)
        # Skip accumulators in this inline execution
        next if stage.accumulator?

        break if current_items.empty?

        next_items = []
        current_items.each do |current_item|
          if stage.respond_to?(:execute_with_emit)
            results = stage.execute_with_emit(context, current_item)
            next_items.concat(results)
          else
            # Consumer - execute but don't collect output
            stage.execute(context, current_item)
          end
        end
        current_items = next_items
      end

      current_items
    end
  end
end
