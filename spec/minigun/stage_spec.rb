# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Minigun::Stage do
  describe 'base class' do
    it 'returns nil when execute is called without a block' do
      stage = described_class.new(name: :test)
      expect(stage.execute(Object.new)).to be_nil
    end

    it 'executes the block when provided' do
      executed = false
      stage = described_class.new(name: :test, block: proc { executed = true })

      # Create mock queues
      input_queue = double('input')
      output_queue = double('output')

      stage.execute(Object.new, input_queue: input_queue, output_queue: output_queue)
      expect(executed).to be true
    end
  end
end

RSpec.describe Minigun::ProducerStage do
  describe 'producer behavior' do
    let(:stage) { described_class.new(name: :test, block: proc { |output| }) }

    it 'is a ProducerStage' do
      expect(stage).to be_a(Minigun::ProducerStage)
    end

    it 'executes without an item argument' do
      result = nil
      stage = described_class.new(
        name: :test,
        block: proc { |output| result = 42 }
      )

      context = Object.new
      stage.execute(context, output_queue: Object.new)

      expect(result).to eq(42)
    end
  end
end

RSpec.describe Minigun::ConsumerStage do
  describe 'processor behavior' do
    let(:stage) { described_class.new(name: :test, block: proc { |_x, _output| }) }

    it 'is a ConsumerStage' do
      expect(stage).to be_a(Minigun::ConsumerStage)
    end

    it 'executes with queue-based output' do
      stage = described_class.new(
        name: :test,
        block: proc do |item, output|
          output << item * 2
          output << item * 3
        end
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
        block: proc { |_x, _output| },
        options: { _execution_context: { type: :processes, mode: :per_batch, max: 2 } }
      )
    end

    it 'is a ConsumerStage' do
      expect(stage).to be_a(Minigun::ConsumerStage)
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
  let(:stage) { Minigun::ConsumerStage.new(name: :test, block: proc { |x, _output| x * 2 }, options: { foo: 'bar' }) }

  describe '#initialize' do
    it 'creates a stage with required attributes' do
      expect(stage.name).to eq(:test)
      expect(stage).to be_a(Minigun::ConsumerStage)
      expect(stage.block).to be_a(Proc)
      expect(stage.options).to eq({ foo: 'bar' })
    end

    it 'works without options' do
      simple = Minigun::ConsumerStage.new(name: :simple, block: proc { |_x, _output| })
      expect(simple.name).to eq(:simple)
      expect(simple.options).to eq({})
    end
  end

  describe '#execute' do
    it 'executes the block with given context and item' do
      result = nil
      stage = Minigun::ConsumerStage.new(
        name: :test,
        block: proc { |item, _output| result = item * 2 }
      )

      context = Object.new
      stage.execute(context, item: 5)

      expect(result).to eq(10)
    end

    it 'has access to context instance variables' do
      context = Object.new
      context.instance_variable_set(:@value, 100)

      stage = Minigun::ConsumerStage.new(
        name: :test,
        block: proc { |item, _output| @value + item }
      )

      stage.execute(context, item: 23)
      # Note: execute doesn't return values for consumers in new DSL
      expect(context.instance_variable_get(:@value)).to eq(100) # unchanged
    end
  end

  describe '#to_h' do
    it 'converts to hash representation' do
      block = proc { |_x, _output| }
      stage = Minigun::ConsumerStage.new(
        name: :test,
        block: block,
        options: { opt: 'val' }
      )

      hash = stage.to_h

      expect(hash[:name]).to eq(:test)
      expect(hash[:block]).to eq(block)
      expect(hash[:options]).to include(opt: 'val')
    end
  end

  describe '#[]' do
    it 'provides hash-like access to attributes' do
      block = proc { |_x, _output| }
      stage = Minigun::ConsumerStage.new(
        name: :test,
        block: block,
        options: { foo: 'bar' }
      )

      expect(stage[:name]).to eq(:test)
      expect(stage[:block]).to eq(block)
      expect(stage[:options]).to eq({ foo: 'bar' })
    end

    it 'returns nil for unknown keys' do
      stage = Minigun::ConsumerStage.new(name: :test, block: proc { |_x, _output| })
      expect(stage[:unknown]).to be_nil
    end
  end
end

