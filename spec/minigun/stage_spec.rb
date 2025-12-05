# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Minigun::Stage do
  let(:config) { { max_threads: 1, max_processes: 1 } }
  let(:task) { Minigun::Task.new(config: config) }
  let(:pipeline) { task.root_pipeline }

  describe 'base class' do
    it 'returns nil when execute is called without a block' do
      stage = described_class.new(:test, pipeline, nil, {})
      input_queue = Queue.new
      output_queue = Queue.new
      expect(stage.execute(Object.new, input_queue, output_queue, nil)).to be_nil
    end

    it 'executes the block when provided' do
      executed = false
      stage = described_class.new(:test, pipeline, proc { executed = true }, {})

      input_queue = Queue.new
      output_queue = Queue.new

      stage.execute(Object.new, input_queue, output_queue, nil)
      expect(executed).to be true
    end
  end

  describe '#initialize' do
    it 'creates a stage with required attributes' do
      stage = Minigun::ConsumerStage.new(:test, pipeline, proc { |x, _output| x * 2 }, { foo: 'bar' })
      expect(stage.name).to eq(:test)
      expect(stage).to be_a(Minigun::ConsumerStage)
      expect(stage.block).to be_a(Proc)
      expect(stage.options).to eq({ foo: 'bar' })
    end

    it 'works without options' do
      simple = Minigun::ConsumerStage.new(:simple, pipeline, proc { |_x, _output| }, {})
      expect(simple.name).to eq(:simple)
      expect(simple.options).to eq({})
    end
  end

  describe '#execute' do
    it 'executes the block with given context and item' do
      result = nil
      stage = Minigun::ConsumerStage.new(
        :test,
        pipeline,
        proc { |item, _output| result = item * 2 },
        {}
      )

      context = Object.new
      input_queue = Queue.new
      output_queue = Queue.new
      input_queue << 5
      input_queue << Minigun::EndOfStage.new(:test)

      stage.execute(context, input_queue, output_queue, nil)

      expect(result).to eq(10)
    end

    it 'has access to context instance variables' do
      context_class = Class.new do
        attr_reader :value

        def initialize(value)
          @value = value
        end
      end
      context = context_class.new(100)

      stage = Minigun::ConsumerStage.new(
        :test,
        pipeline,
        proc { |item, _output| @value + item },
        {}
      )

      input_queue = Queue.new
      output_queue = Queue.new
      input_queue << 23
      input_queue << Minigun::EndOfStage.new(:test)

      stage.execute(context, input_queue, output_queue, nil)
      # NOTE: execute doesn't return values for consumers in new DSL
      expect(context.value).to eq(100) # unchanged
    end
  end

  describe '#to_h' do
    it 'converts to hash representation' do
      block = proc { |_x, _output| }
      stage = Minigun::ConsumerStage.new(
        :test,
        pipeline,
        block,
        { opt: 'val' }
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
        :test,
        pipeline,
        block,
        { foo: 'bar' }
      )

      expect(stage[:name]).to eq(:test)
      expect(stage[:block]).to eq(block)
      expect(stage[:options]).to eq({ foo: 'bar' })
    end

    it 'returns nil for unknown keys' do
      stage = Minigun::ConsumerStage.new(:test, pipeline, proc { |_x, _output| }, {})
      expect(stage[:unknown]).to be_nil
    end
  end
end

RSpec.describe Minigun::ProducerStage do
  let(:config) { { max_threads: 1, max_processes: 1 } }
  let(:task) { Minigun::Task.new(config: config) }
  let(:pipeline) { task.root_pipeline }

  describe 'producer behavior' do
    let(:stage) { described_class.new(:test, pipeline, proc { |output| }, {}) }

    it 'is a ProducerStage' do
      expect(stage).to be_a(described_class)
    end

    it 'executes without an item argument' do
      result = nil
      stage = described_class.new(
        :test,
        pipeline,
        proc { |_output| result = 42 },
        {}
      )

      context = Object.new
      stage.execute(context, nil, Object.new, nil)

      expect(result).to eq(42)
    end
  end
end

RSpec.describe Minigun::EnumeratorProducerStage do
  let(:config) { { max_threads: 1, max_processes: 1 } }
  let(:task) { Minigun::Task.new(config: config) }
  let(:pipeline) { task.root_pipeline }

  describe 'source types' do
    it 'is a ProducerStage subclass' do
      stage = described_class.new(:test, pipeline, [1, 2, 3])
      expect(stage).to be_a(Minigun::ProducerStage)
    end

    it 'iterates over an array' do
      stage = described_class.new(:test, pipeline, [1, 2, 3])

      emitted = []
      output_queue = Object.new
      output_queue.define_singleton_method(:<<) { |item| emitted << item }

      stage.execute(Object.new, nil, output_queue, nil)

      expect(emitted).to eq([1, 2, 3])
    end

    it 'iterates over a range' do
      stage = described_class.new(:test, pipeline, 1..3)

      emitted = []
      output_queue = Object.new
      output_queue.define_singleton_method(:<<) { |item| emitted << item }

      stage.execute(Object.new, nil, output_queue, nil)

      expect(emitted).to eq([1, 2, 3])
    end

    it 'calls a proc and iterates result' do
      stage = described_class.new(:test, pipeline, -> { [10, 20, 30] })

      emitted = []
      output_queue = Object.new
      output_queue.define_singleton_method(:<<) { |item| emitted << item }

      stage.execute(Object.new, nil, output_queue, nil)

      expect(emitted).to eq([10, 20, 30])
    end

    it 'calls a method symbol on context and iterates result' do
      stage = described_class.new(:test, pipeline, :fetch_items)

      context = Object.new
      context.define_singleton_method(:fetch_items) { [100, 200] }

      emitted = []
      output_queue = Object.new
      output_queue.define_singleton_method(:<<) { |item| emitted << item }

      stage.execute(context, nil, output_queue, nil)

      expect(emitted).to eq([100, 200])
    end

    it 'stores the source' do
      source = [1, 2, 3]
      stage = described_class.new(:test, pipeline, source)
      expect(stage.source).to eq(source)
    end
  end
end

RSpec.describe Minigun::ConsumerStage do
  let(:config) { { max_threads: 1, max_processes: 1 } }
  let(:task) { Minigun::Task.new(config: config) }
  let(:pipeline) { task.root_pipeline }

  describe 'processor behavior' do
    let(:stage) { described_class.new(:test, pipeline, proc { |_x, _output| }, {}) }

    it 'is a ConsumerStage' do
      expect(stage).to be_a(described_class)
    end

    it 'executes with queue-based output' do
      stage = described_class.new(
        :test,
        pipeline,
        proc do |item, output|
          output << (item * 2)
          output << (item * 3)
        end,
        {}
      )

      context = Object.new
      emitted = []
      output_queue = Object.new
      output_queue.define_singleton_method(:<<) { |item| emitted << item }

      input_queue = Queue.new
      input_queue << 5
      input_queue << Minigun::EndOfStage.new(:test)

      stage.execute(context, input_queue, output_queue, nil)

      expect(emitted).to eq([10, 15])
    end
  end

  describe 'consumer behavior (has execution context)' do
    let(:stage) do
      described_class.new(
        :test,
        pipeline,
        proc { |_x, _output| },
        { _execution_context: { type: :cow_forks, mode: :per_batch, max: 2 } }
      )
    end

    it 'is a ConsumerStage' do
      expect(stage).to be_a(described_class)
    end

    it 'has execution context' do
      expect(stage.execution_context).to eq({ type: :cow_forks, mode: :per_batch, max: 2 })
    end
  end
end

RSpec.describe Minigun::BatchStage do
  let(:config) { { max_threads: 1, max_processes: 1 } }
  let(:task) { Minigun::Task.new(config: config) }
  let(:pipeline) { task.root_pipeline }

  describe 'initialization' do
    it 'has default max_size of 100' do
      stage = described_class.new(:test, pipeline, proc {}, {})
      expect(stage.max_size).to eq(100)
    end

    it 'has default max_wait of nil' do
      stage = described_class.new(:test, pipeline, proc {}, {})
      expect(stage.max_wait).to be_nil
    end

    it 'accepts custom max_size' do
      stage = described_class.new(:test, pipeline, proc {}, { max_size: 50 })
      expect(stage.max_size).to eq(50)
    end

    it 'accepts max_wait option' do
      stage = described_class.new(:test, pipeline, proc {}, { max_wait: 5.0 })
      expect(stage.max_wait).to eq(5.0)
    end

    it 'accepts both max_size and max_wait' do
      stage = described_class.new(:test, pipeline, proc {}, { max_size: 25, max_wait: 2.5 })
      expect(stage.max_size).to eq(25)
      expect(stage.max_wait).to eq(2.5)
    end
  end
end
