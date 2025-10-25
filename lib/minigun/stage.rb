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

    # Get execution strategy
    def strategy
      @strategy
    end

    # Whether this stage has a spawn strategy (fork, thread, ractor)
    def has_spawn_strategy?
      [:spawn_thread, :spawn_fork, :spawn_ractor].include?(@strategy)
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
    end

    def accumulator?
      true
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

      # Process item through nested pipeline stages sequentially
      current_items = [item]

      @pipeline.stage_order.each do |stage_name|
        stage = @pipeline.find_stage(stage_name)
        next unless stage
        next if stage.producer?  # Skip producers in nested pipelines

        break if current_items.empty?

        next_items = []
        current_items.each do |current_item|
          results = stage.execute_with_emit(context, current_item)
          next_items.concat(results)
        end
        current_items = next_items
      end

      current_items
    end
  end
end
