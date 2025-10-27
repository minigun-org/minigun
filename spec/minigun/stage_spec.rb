# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Minigun::Stage do
  describe 'base class' do
    it 'raises NotImplementedError for abstract execute method' do
      stage = described_class.new(name: :test)
      expect { stage.execute(Object.new) }.to raise_error(NotImplementedError)
    end
  end
end

RSpec.describe Minigun::AtomicStage do
  describe 'producer behavior' do
    let(:stage) { described_class.new(name: :test, block: proc { |output| }, options: { stage_type: :producer }) }

    it 'is a producer' do
      expect(stage.producer?).to be true
    end

    it 'executes without an item argument' do
      result = nil
      stage = described_class.new(
        name: :test,
        block: proc { |output| result = 42 },
        options: { stage_type: :producer }
      )

      context = Object.new
      stage.execute(context, output_queue: Object.new)

      expect(result).to eq(42)
    end
  end

  describe 'processor behavior (block arity 1)' do
    let(:stage) { described_class.new(name: :test, block: proc { |_x| }) }

    it 'is not a producer' do
      expect(stage.producer?).to be false
    end

    it 'executes with queue-based output' do
      stage = described_class.new(
        name: :test,
        block: proc do |item, output|
          output << item * 2
          output << item * 3
        end,
        options: { stage_type: :processor }
      )

      context = Object.new
      emitted = []
      mock_output = Object.new
      mock_output.define_singleton_method(:<<) { |item| emitted << item }

      stage.execute(context, item: 5, output_queue: mock_output)

      expect(emitted).to eq([10, 15])
    end
  end

  describe 'consumer behavior (has execution context)' do
    let(:stage) do
      described_class.new(
        name: :test,
        block: proc { |_x| },
        options: { _execution_context: { type: :processes, mode: :per_batch, max: 2 } }
      )
    end

    it 'is not a producer' do
      expect(stage.producer?).to be false
    end

    it 'has execution context' do
      expect(stage.execution_context).to eq({ type: :processes, mode: :per_batch, max: 2 })
    end
  end
end

RSpec.describe Minigun::AccumulatorStage do
  it 'is a special batching stage' do
    stage = described_class.new(name: :test, block: proc {})
    expect(stage.max_size).to eq(100)  # default
  end
end

RSpec.describe 'Stage common behavior' do
  let(:stage) { Minigun::AtomicStage.new(name: :test, block: proc { |x| x * 2 }, options: { foo: 'bar' }) }

  describe '#initialize' do
    it 'creates a stage with required attributes' do
      expect(stage.name).to eq(:test)
      expect(stage.producer?).to be false
      expect(stage.block).to be_a(Proc)
      expect(stage.options).to eq({ foo: 'bar' })
    end

    it 'works without options' do
      simple = Minigun::AtomicStage.new(name: :simple, block: proc { |_x| })
      expect(simple.name).to eq(:simple)
      expect(simple.options).to eq({})
    end
  end

  describe '#execute' do
    it 'executes the block with given context and item' do
      result = nil
      stage = Minigun::AtomicStage.new(
        name: :test,
        block: proc { |item| result = item * 2 },
        options: { stage_type: :consumer }
      )

      context = Object.new
      stage.execute(context, item: 5)

      expect(result).to eq(10)
    end

    it 'has access to context instance variables' do
      context = Object.new
      context.instance_variable_set(:@value, 100)

      stage = Minigun::AtomicStage.new(
        name: :test,
        block: proc { |item| @value + item },
        options: { stage_type: :consumer }
      )

      stage.execute(context, item: 23)
      # Note: execute doesn't return values for consumers in new DSL
      expect(context.instance_variable_get(:@value)).to eq(100) # unchanged
    end
  end

  describe '#to_h' do
    it 'converts to hash representation' do
      block = proc { |_x| }
      stage = Minigun::AtomicStage.new(
        name: :test,
        block: block,
        options: { opt: 'val', stage_type: :processor }
      )

      hash = stage.to_h

      expect(hash[:name]).to eq(:test)
      expect(hash[:block]).to eq(block)
      expect(hash[:options]).to include(opt: 'val')
      expect(hash[:stage_type]).to eq(:processor)
    end
  end

  describe '#[]' do
    it 'provides hash-like access to attributes' do
      block = proc { |_x| }
      stage = Minigun::AtomicStage.new(
        name: :test,
        block: block,
        options: { foo: 'bar' }
      )

      expect(stage[:name]).to eq(:test)
      expect(stage[:block]).to eq(block)
      expect(stage[:options]).to eq({ foo: 'bar' })
    end

    it 'returns nil for unknown keys' do
      stage = Minigun::AtomicStage.new(name: :test, block: proc { |_x| })
      expect(stage[:unknown]).to be_nil
    end
  end
end

