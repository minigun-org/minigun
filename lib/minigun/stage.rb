# frozen_string_literal: true

module Minigun
  # Base class for pipeline stages
  class Stage
    attr_reader :name, :block, :options

    def initialize(name:, block:, options: {})
      @name = name
      @block = block
      @options = options
    end

    # Return the stage type (overridden in subclasses)
    def type
      raise NotImplementedError, "Subclasses must implement #type"
    end

    # Execute the stage with the given context and item
    def execute(context, item)
      context.instance_exec(item, &@block)
    end

    # Whether this stage should emit items (overridden in subclasses)
    def emits?
      false
    end

    # Whether this stage is terminal (no downstream stages)
    def terminal?
      false
    end

    # Convert to hash (for backward compatibility)
    def to_h
      { name: @name, type: type, block: @block, options: @options }
    end

    # Allow hash-like access for backward compatibility
    def [](key)
      case key
      when :name then @name
      when :type then type
      when :block then @block
      when :options then @options
      else nil
      end
    end
  end

  # Producer stage - generates items
  class ProducerStage < Stage
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

  # Processor stage - transforms items
  class ProcessorStage < Stage
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

  # Accumulator stage - batches items (currently unused in new architecture)
  class AccumulatorStage < Stage
    def type
      :accumulator
    end
  end

  # Consumer stage - terminal stage that processes final items
  class ConsumerStage < Stage
    def type
      :consumer
    end

    def terminal?
      true
    end

    # Consumers don't emit, they just process
    def emits?
      false
    end
  end
end

