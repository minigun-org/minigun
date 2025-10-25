# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Minigun::Stage do
  describe 'base class' do
    it 'raises NotImplementedError for abstract type method' do
      stage = described_class.new(name: :test, block: proc {})
      expect { stage.type }.to raise_error(NotImplementedError)
    end
  end
end

RSpec.describe Minigun::ProducerStage do
  describe '#type' do
    it 'returns :producer' do
      stage = described_class.new(name: :test, block: proc {})
      expect(stage.type).to eq(:producer)
    end
  end

  describe '#emits?' do
    it 'returns true' do
      stage = described_class.new(name: :test, block: proc {})
      expect(stage.emits?).to be true
    end
  end

  describe '#terminal?' do
    it 'returns false' do
      stage = described_class.new(name: :test, block: proc {})
      expect(stage.terminal?).to be false
    end
  end

  describe '#execute' do
    it 'executes without an item argument' do
      result = nil
      stage = described_class.new(
        name: :test,
        block: proc { result = 42 }
      )

      context = Object.new
      stage.execute(context)

      expect(result).to eq(42)
    end
  end
end

RSpec.describe Minigun::ProcessorStage do
  describe '#type' do
    it 'returns :processor' do
      stage = described_class.new(name: :test, block: proc {})
      expect(stage.type).to eq(:processor)
    end
  end

  describe '#emits?' do
    it 'returns true' do
      stage = described_class.new(name: :test, block: proc {})
      expect(stage.emits?).to be true
    end
  end

  describe '#execute_with_emit' do
    it 'returns emitted items' do
      stage = described_class.new(
        name: :test,
        block: proc do |item|
          emit(item * 2)
          emit(item * 3)
        end
      )

      context = Object.new
      emitted = stage.execute_with_emit(context, 5)

      expect(emitted).to eq([10, 15])
    end
  end
end

RSpec.describe Minigun::ConsumerStage do
  describe '#type' do
    it 'returns :consumer' do
      stage = described_class.new(name: :test, block: proc {})
      expect(stage.type).to eq(:consumer)
    end
  end

  describe '#emits?' do
    it 'returns false' do
      stage = described_class.new(name: :test, block: proc {})
      expect(stage.emits?).to be false
    end
  end

  describe '#terminal?' do
    it 'returns true' do
      stage = described_class.new(name: :test, block: proc {})
      expect(stage.terminal?).to be true
    end
  end
end

RSpec.describe Minigun::AccumulatorStage do
  describe '#type' do
    it 'returns :accumulator' do
      stage = described_class.new(name: :test, block: proc {})
      expect(stage.type).to eq(:accumulator)
    end
  end
end

RSpec.describe 'Stage common behavior' do
  let(:stage) { Minigun::ProcessorStage.new(name: :test, block: proc { |x| x * 2 }, options: { foo: 'bar' }) }

  describe '#initialize' do
    it 'creates a stage with required attributes' do
      expect(stage.name).to eq(:test)
      expect(stage.type).to eq(:processor)
      expect(stage.block).to be_a(Proc)
      expect(stage.options).to eq({ foo: 'bar' })
    end

    it 'works without options' do
      simple = Minigun::ConsumerStage.new(name: :simple, block: proc {})
      expect(simple.name).to eq(:simple)
      expect(simple.options).to eq({})
    end
  end

  describe '#execute' do
    it 'executes the block with given context and item' do
      result = nil
      stage = Minigun::ProcessorStage.new(
        name: :test,
        block: proc { |item| result = item * 2 }
      )

      context = Object.new
      stage.execute(context, 5)

      expect(result).to eq(10)
    end

    it 'has access to context instance variables' do
      context = Object.new
      context.instance_variable_set(:@value, 100)

      stage = Minigun::ProcessorStage.new(
        name: :test,
        block: proc { |item| @value + item }
      )

      result = stage.execute(context, 23)
      expect(result).to eq(123)
    end
  end

  describe '#to_h' do
    it 'converts to hash representation' do
      block = proc {}
      stage = Minigun::ProcessorStage.new(
        name: :test,
        block: block,
        options: { opt: 'val' }
      )

      hash = stage.to_h

      expect(hash).to eq({
        name: :test,
        type: :processor,
        block: block,
        options: { opt: 'val' }
      })
    end
  end

  describe '#[]' do
    it 'provides hash-like access to attributes' do
      block = proc {}
      stage = Minigun::ProcessorStage.new(
        name: :test,
        block: block,
        options: { foo: 'bar' }
      )

      expect(stage[:name]).to eq(:test)
      expect(stage[:type]).to eq(:processor)
      expect(stage[:block]).to eq(block)
      expect(stage[:options]).to eq({ foo: 'bar' })
    end

    it 'returns nil for unknown keys' do
      stage = Minigun::ProcessorStage.new(name: :test, block: proc {})
      expect(stage[:unknown]).to be_nil
    end
  end
end

