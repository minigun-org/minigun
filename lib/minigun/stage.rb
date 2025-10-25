# frozen_string_literal: true

module Minigun
  # Base class for all execution units (stages and pipelines)
  # Implements the Composite pattern where Pipeline is a composite Stage
  class Stage
    attr_reader :name, :options

    def initialize(name:, options: {})
      @name = name
      @options = options
      @strategy = options[:strategy] || :threaded
    end

    # Return the stage type (overridden in subclasses)
    def type
      raise NotImplementedError, "Subclasses must implement #type"
    end

    # Execute the stage with the given context and item
    # Returns emitted items for routing (if applicable)
    def execute(context, item = nil)
      raise NotImplementedError, "Subclasses must implement #execute"
    end

    # Whether this stage should emit items (overridden in subclasses)
    def emits?
      false
    end

    # Whether this stage is terminal (no downstream stages)
    def terminal?
      false
    end

    # Whether this stage is composite (contains other stages)
    def composite?
      false
    end

    # Get execution strategy
    def strategy
      @strategy
    end

    # Convert to hash (for backward compatibility)
    def to_h
      { name: @name, type: type, options: @options }
    end

    # Allow hash-like access for backward compatibility
    def [](key)
      case key
      when :name then @name
      when :type then type
      when :options then @options
      else nil
      end
    end
  end

  # Atomic stages - leaf nodes that execute a single block
  class AtomicStage < Stage
    attr_reader :block

    def initialize(name:, block:, options: {})
      super(name: name, options: options)
      @block = block
    end

    # Execute the stage block with context and item
    def execute(context, item)
      context.instance_exec(item, &@block)
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

  # Producer stage - generates items (no input)
  class ProducerStage < AtomicStage
    def type
      :producer
    end

    def emits?
      true
    end

    # Producers execute without items (they generate items)
    def execute(context, _item = nil)
      context.instance_eval(&@block)
    end
  end

  # Processor stage - transforms items (input → output)
  class ProcessorStage < AtomicStage
    def type
      :processor
    end

    def emits?
      true
    end

    # Execute and return emitted items
    def execute_with_emit(context, item)
      emitted_items = []
      emit_proc = proc { |i| emitted_items << i }
      context.define_singleton_method(:emit, &emit_proc)

      execute(context, item)

      emitted_items
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
    end

    def type
      :accumulator
    end

    def emits?
      true  # Accumulator emits batches
    end

    # Accumulator doesn't execute per-item - it batches
    # The batching logic happens in Pipeline
    def execute(context, batch)
      # If there's custom logic, execute it
      # Otherwise just pass through the batch
      if @block
        context.instance_exec(batch, &@block)
      else
        batch
      end
    end
  end

  # Consumer stage - terminal stage that processes final items (no output)
  class ConsumerStage < AtomicStage
    def type
      :consumer
    end

    def terminal?
      true
    end

    def emits?
      false
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

    def type
      :pipeline
    end

    def composite?
      true
    end

    def emits?
      # A pipeline emits if it has output connections
      true
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

      emitted_items = []

      # Process the item through the nested pipeline's stages
      # Start with the input item
      current_items = [item]

      # Execute processors in sequence
      @pipeline.stages[:processor].each do |processor_stage|
        next_items = []
        current_items.each do |current_item|
          # Execute before hooks for this stage
          @pipeline.send(:execute_stage_hooks, :before, processor_stage.name)

          # Execute the processor
          results = processor_stage.execute_with_emit(context, current_item)
          next_items.concat(results)

          # Execute after hooks for this stage
          @pipeline.send(:execute_stage_hooks, :after, processor_stage.name)
        end
        current_items = next_items
      end

      # Execute consumers if any (they don't emit, but we should still run them)
      unless @pipeline.stages[:consumer].empty?
        current_items.each do |current_item|
          @pipeline.stages[:consumer].each do |consumer_stage|
            # Execute before hooks
            @pipeline.send(:execute_stage_hooks, :before, consumer_stage.name)

            # Execute consumer
            consumer_stage.execute(context, current_item)

            # Execute after hooks
            @pipeline.send(:execute_stage_hooks, :after, consumer_stage.name)
          end
        end
      end

      # Return the items for the parent pipeline to continue processing
      current_items
    end
  end
end
