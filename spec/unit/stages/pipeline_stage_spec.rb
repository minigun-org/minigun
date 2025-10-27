# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Minigun::PipelineStage do
  let(:config) { { max_threads: 2, max_processes: 1 } }

  describe '#initialize' do
    it 'creates a PipelineStage without a pipeline initially' do
      stage = described_class.new(name: :my_pipeline)
      expect(stage.name).to eq(:my_pipeline)
      expect(stage.pipeline).to be_nil
    end
  end

  describe '#composite?' do
    it 'returns true' do
      stage = described_class.new(name: :my_pipeline)
      expect(stage).to be_a(described_class)
    end
  end

  describe '#pipeline=' do
    it 'sets the pipeline' do
      stage = described_class.new(name: :my_pipeline)
      pipeline = Minigun::Pipeline.new(:test, config)

      stage.pipeline = pipeline

      expect(stage.pipeline).to eq(pipeline)
    end

    it 'adds queued stages to the pipeline' do
      stage = described_class.new(name: :my_pipeline)

      # Queue stages before pipeline exists
      stage.add_stage(:producer, :source) { emit(1) }
      stage.add_stage(:consumer, :sink) { |item| item * 2 }

      # Now create and attach pipeline
      pipeline = Minigun::Pipeline.new(:test, config)
      stage.pipeline = pipeline

      expect(pipeline.stages.keys).to include(:source, :sink)
    end
  end

  describe '#add_stage' do
    it 'queues stages when pipeline is not yet set' do
      stage = described_class.new(name: :my_pipeline)

      stage.add_stage(:producer, :source) { emit(1) }

      expect(stage.stages_to_add.size).to eq(1)
    end

    it 'adds stages directly when pipeline exists' do
      stage = described_class.new(name: :my_pipeline)
      pipeline = Minigun::Pipeline.new(:test, config)
      stage.pipeline = pipeline

      stage.add_stage(:producer, :source) { emit(1) }

      expect(pipeline.stages[:source]).to be_a(Minigun::ProducerStage)
    end
  end

  describe '#execute' do
    it 'executes the pipeline stages inline and returns results' do
      stage = described_class.new(name: :my_pipeline)
      pipeline = Minigun::Pipeline.new(:test, config)
      stage.pipeline = pipeline

      # Add processor to pipeline (no consumer, so output is returned)
      pipeline.add_stage(:processor, :double) { |item, output| output << (item * 2) }

      context = Object.new
      output_queue = []
      output_queue.define_singleton_method(:<<) do |item|
        push(item)
        self
      end

      stage.execute(context, item: 5, output_queue: output_queue)

      # PipelineStage now pushes results to output queue
      expect(output_queue).to include(10)
    end
  end

  describe '#execute with queue-based DSL' do
    let(:create_output_queue) do
      [].tap do |arr|
        arr.define_singleton_method(:<<) do |item|
          push(item)
          self
        end
      end
    end

    it 'returns the item unchanged if no pipeline is set' do
      stage = described_class.new(name: :my_pipeline)
      context = Object.new
      output_queue = create_output_queue

      stage.execute(context, item: 42, output_queue: output_queue)

      expect(output_queue).to eq([42])
    end

    it 'processes item through pipeline stages sequentially' do
      stage = described_class.new(name: :my_pipeline)
      pipeline = Minigun::Pipeline.new(:test, config)
      stage.pipeline = pipeline

      # Add stages that transform the item
      pipeline.add_stage(:processor, :double) { |item, output| output << (item * 2) }
      pipeline.add_stage(:processor, :add_ten) { |item, output| output << (item + 10) }

      context = Object.new
      output_queue = create_output_queue

      stage.execute(context, item: 5, output_queue: output_queue)

      # 5 * 2 = 10, then 10 + 10 = 20
      expect(output_queue).to eq([20])
    end

    it 'skips producer stages' do
      stage = described_class.new(name: :my_pipeline)
      pipeline = Minigun::Pipeline.new(:test, config)
      stage.pipeline = pipeline

      # Add a producer (should be skipped) and a processor
      pipeline.add_stage(:producer, :source) { |output| output << 999 }
      pipeline.add_stage(:processor, :double) { |item, output| output << (item * 2) }

      context = Object.new
      output_queue = create_output_queue

      stage.execute(context, item: 5, output_queue: output_queue)

      # Should process 5, not 999 from producer
      expect(output_queue).to eq([10])
    end

    it 'processes through accumulator stages' do
      stage = described_class.new(name: :my_pipeline)
      pipeline = Minigun::Pipeline.new(:test, config)
      stage.pipeline = pipeline

      pipeline.add_stage(:processor, :double) { |item, output| output << (item * 2) }
      pipeline.add_stage(:accumulator, :batch, max_size: 2) # Small batch for testing
      pipeline.add_stage(:processor, :sum_batch) { |batch, output| output << batch.sum }

      context = Object.new

      # First item: buffered by accumulator
      output_queue1 = create_output_queue
      stage.execute(context, item: 5, output_queue: output_queue1)
      expect(output_queue1).to eq([]) # Nothing emitted yet

      # Second item: accumulator reaches batch size and emits
      output_queue2 = create_output_queue
      stage.execute(context, item: 3, output_queue: output_queue2)

      # Accumulator emits [10, 6], sum_batch processes it: 10 + 6 = 16
      expect(output_queue2).to eq([16])
    end

    it 'handles multiple outputs per stage' do
      stage = described_class.new(name: :my_pipeline)
      pipeline = Minigun::Pipeline.new(:test, config)
      stage.pipeline = pipeline

      # Stage that outputs multiple items
      pipeline.add_stage(:processor, :fan_out) do |item, output|
        output << item
        output << (item * 10)
      end

      context = Object.new
      output_queue = create_output_queue

      stage.execute(context, item: 5, output_queue: output_queue)

      expect(output_queue).to contain_exactly(5, 50)
    end

    it 'executes consumer stages but does not collect their output' do
      stage = described_class.new(name: :my_pipeline)
      pipeline = Minigun::Pipeline.new(:test, config)
      stage.pipeline = pipeline

      results = []
      pipeline.add_stage(:processor, :double) { |item, output| output << (item * 2) }
      pipeline.add_stage(:consumer, :collect) { |item| results << item }

      context = Object.new
      output_queue = create_output_queue

      stage.execute(context, item: 5, output_queue: output_queue)

      # Consumer executed (side effect)
      expect(results).to eq([10])
      # But nothing pushed to output queue after consumer
      expect(output_queue).to eq([])
    end

    it 'handles empty results from stages' do
      stage = described_class.new(name: :my_pipeline)
      pipeline = Minigun::Pipeline.new(:test, config)
      stage.pipeline = pipeline

      # Stage that filters out items
      pipeline.add_stage(:processor, :filter) do |item, output|
        output << item if item > 10
      end

      context = Object.new
      output_queue = create_output_queue

      stage.execute(context, item: 5, output_queue: output_queue)

      expect(output_queue).to eq([])
    end

    it 'chains multiple transformations correctly' do
      stage = described_class.new(name: :my_pipeline)
      pipeline = Minigun::Pipeline.new(:test, config)
      stage.pipeline = pipeline

      pipeline.add_stage(:processor, :double) { |item, output| output << (item * 2) }
      pipeline.add_stage(:processor, :square) { |item, output| output << (item**2) }
      pipeline.add_stage(:processor, :add_one) { |item, output| output << (item + 1) }

      context = Object.new
      output_queue = create_output_queue

      stage.execute(context, item: 3, output_queue: output_queue)

      # 3 * 2 = 6, 6^2 = 36, 36 + 1 = 37
      expect(output_queue).to eq([37])
    end

    it 'skips nested PipelineStages' do
      stage = described_class.new(name: :outer)
      pipeline = Minigun::Pipeline.new(:outer, config)
      stage.pipeline = pipeline

      # Add a nested pipeline stage
      inner_stage = described_class.new(name: :inner)
      inner_pipeline = Minigun::Pipeline.new(:inner, config)
      inner_stage.pipeline = inner_pipeline
      pipeline.stages[:inner] = inner_stage

      pipeline.add_stage(:processor, :double) { |item, output| output << (item * 2) }

      context = Object.new
      output_queue = create_output_queue

      stage.execute(context, item: 5, output_queue: output_queue)

      # Should skip nested pipeline, only run double
      expect(output_queue).to eq([10])
    end

    it 'handles stages that output nothing' do
      stage = described_class.new(name: :my_pipeline)
      pipeline = Minigun::Pipeline.new(:test, config)
      stage.pipeline = pipeline

      # Stage that never outputs
      pipeline.add_stage(:processor, :black_hole) { |_item, _output| nil }

      context = Object.new
      output_queue = create_output_queue

      stage.execute(context, item: 5, output_queue: output_queue)

      expect(output_queue).to eq([])
    end

    it 'preserves context instance variables across stages' do
      stage = described_class.new(name: :my_pipeline)
      pipeline = Minigun::Pipeline.new(:test, config)
      stage.pipeline = pipeline

      context = Class.new do
        attr_accessor :tracking

        def initialize
          @tracking = []
        end
      end.new

      pipeline.add_stage(:processor, :track_and_double) do |item, output|
        tracking << "saw #{item}"
        output << (item * 2)
      end

      output_queue = create_output_queue

      stage.execute(context, item: 5, output_queue: output_queue)

      expect(output_queue).to eq([10])
      expect(context.tracking).to eq(['saw 5'])
    end
  end
end
