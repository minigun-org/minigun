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
  describe 'producer behavior (block arity 0)' do
    let(:stage) { described_class.new(name: :test, block: proc {}) }

    it 'is a producer' do
      expect(stage.producer?).to be true
    end

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

  describe 'processor behavior (block arity 1)' do
    let(:stage) { described_class.new(name: :test, block: proc { |_x| }) }

    it 'is not a producer' do
      expect(stage.producer?).to be false
    end

    it 'executes with emit and returns emitted items' do
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
        block: proc { |item| result = item * 2 }
      )

      context = Object.new
      stage.execute(context, 5)

      expect(result).to eq(10)
    end

    it 'has access to context instance variables' do
      context = Object.new
      context.instance_variable_set(:@value, 100)

      stage = Minigun::AtomicStage.new(
        name: :test,
        block: proc { |item| @value + item }
      )

      result = stage.execute(context, 23)
      expect(result).to eq(123)
    end
  end

  describe '#to_h' do
    it 'converts to hash representation' do
      block = proc { |_x| }
      stage = Minigun::AtomicStage.new(
        name: :test,
        block: block,
        options: { opt: 'val' }
      )

      hash = stage.to_h

      expect(hash).to eq({
        name: :test,
        block: block,
        options: { opt: 'val' }
      })
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

