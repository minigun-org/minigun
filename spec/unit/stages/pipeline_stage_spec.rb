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
      expect(stage.composite?).to be true
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

      expect(stage.instance_variable_get(:@stages_to_add).size).to eq(1)
    end

    it 'adds stages directly when pipeline exists' do
      stage = described_class.new(name: :my_pipeline)
      pipeline = Minigun::Pipeline.new(:test, config)
      stage.pipeline = pipeline

      stage.add_stage(:producer, :source) { emit(1) }

      expect(pipeline.stages[:source]).to be_a(Minigun::AtomicStage)
    end
  end

  describe '#execute' do
    it 'executes the pipeline stages inline and returns results' do
      stage = described_class.new(name: :my_pipeline)
      pipeline = Minigun::Pipeline.new(:test, config)
      stage.pipeline = pipeline

      # Add processor and consumer to pipeline
      pipeline.add_stage(:processor, :double) { |item| emit(item * 2) }
      pipeline.add_stage(:consumer, :sink) { |item| item }

      context = Object.new
      result = stage.execute(context, 5)

      # PipelineStage now returns results to flow downstream in per-edge queue architecture
      expect(result).to be_an(Array)
    end
  end

  describe '#execute_with_emit' do
    it 'returns the item unchanged if no pipeline is set' do
      stage = described_class.new(name: :my_pipeline)

      context = Object.new
      result = stage.execute_with_emit(context, 42)

      expect(result).to eq([42])
    end

    it 'processes item through pipeline stages sequentially' do
      stage = described_class.new(name: :my_pipeline)
      pipeline = Minigun::Pipeline.new(:test, config)
      stage.pipeline = pipeline

      # Add stages that transform the item
      pipeline.add_stage(:processor, :double) { |item| emit(item * 2) }
      pipeline.add_stage(:processor, :add_ten) { |item| emit(item + 10) }

      context = Object.new
      result = stage.execute_with_emit(context, 5)

      # 5 * 2 = 10, then 10 + 10 = 20
      expect(result).to eq([20])
    end

    it 'skips producer stages' do
      stage = described_class.new(name: :my_pipeline)
      pipeline = Minigun::Pipeline.new(:test, config)
      stage.pipeline = pipeline

      # Add a producer (should be skipped) and a processor
      pipeline.add_stage(:producer, :source) { emit(999) }
      pipeline.add_stage(:processor, :double) { |item| emit(item * 2) }

      context = Object.new
      result = stage.execute_with_emit(context, 5)

      # Should process 5, not 999 from producer
      expect(result).to eq([10])
    end

    it 'processes through accumulator stages' do
      stage = described_class.new(name: :my_pipeline)
      pipeline = Minigun::Pipeline.new(:test, config)
      stage.pipeline = pipeline

      pipeline.add_stage(:processor, :double) { |item| emit(item * 2) }
      pipeline.add_stage(:accumulator, :batch, max_size: 2)  # Small batch for testing
      pipeline.add_stage(:processor, :sum_batch) { |batch| emit(batch.sum) }

      context = Object.new

      # First item: buffered by accumulator
      result = stage.execute_with_emit(context, 5)
      expect(result).to eq([])  # Nothing emitted yet

      # Second item: accumulator reaches batch size and emits
      result = stage.execute_with_emit(context, 3)

      # Accumulator emits [10, 6], sum_batch processes it: 10 + 6 = 16
      expect(result).to eq([16])
    end

    it 'handles multiple emits per stage' do
      stage = described_class.new(name: :my_pipeline)
      pipeline = Minigun::Pipeline.new(:test, config)
      stage.pipeline = pipeline

      # Stage that emits multiple items
      pipeline.add_stage(:processor, :fan_out) do |item|
        emit(item)
        emit(item * 10)
      end

      context = Object.new
      result = stage.execute_with_emit(context, 5)

      expect(result).to contain_exactly(5, 50)
    end

    it 'executes consumer stages but does not collect their output' do
      stage = described_class.new(name: :my_pipeline)
      pipeline = Minigun::Pipeline.new(:test, config)
      stage.pipeline = pipeline

      results = []
      pipeline.add_stage(:processor, :double) { |item| emit(item * 2) }
      pipeline.add_stage(:consumer, :collect) { |item| results << item }

      context = Object.new
      result = stage.execute_with_emit(context, 5)

      # Consumer executed (side effect)
      expect(results).to eq([10])
      # But nothing returned
      expect(result).to eq([])
    end

    it 'handles empty results from stages' do
      stage = described_class.new(name: :my_pipeline)
      pipeline = Minigun::Pipeline.new(:test, config)
      stage.pipeline = pipeline

      # Stage that filters out items
      pipeline.add_stage(:processor, :filter) do |item|
        emit(item) if item > 10
      end

      context = Object.new
      result = stage.execute_with_emit(context, 5)

      expect(result).to eq([])
    end

    it 'chains multiple transformations correctly' do
      stage = described_class.new(name: :my_pipeline)
      pipeline = Minigun::Pipeline.new(:test, config)
      stage.pipeline = pipeline

      pipeline.add_stage(:processor, :double) { |item| emit(item * 2) }
      pipeline.add_stage(:processor, :square) { |item| emit(item ** 2) }
      pipeline.add_stage(:processor, :add_one) { |item| emit(item + 1) }

      context = Object.new
      result = stage.execute_with_emit(context, 3)

      # 3 * 2 = 6, 6^2 = 36, 36 + 1 = 37
      expect(result).to eq([37])
    end

    it 'skips nested PipelineStages' do
      stage = described_class.new(name: :outer)
      pipeline = Minigun::Pipeline.new(:outer, config)
      stage.pipeline = pipeline

      # Add a nested pipeline stage
      inner_stage = Minigun::PipelineStage.new(name: :inner)
      inner_pipeline = Minigun::Pipeline.new(:inner, config)
      inner_stage.pipeline = inner_pipeline
      pipeline.stages[:inner] = inner_stage

      pipeline.add_stage(:processor, :double) { |item| emit(item * 2) }

      context = Object.new
      result = stage.execute_with_emit(context, 5)

      # Should skip nested pipeline, only run double
      expect(result).to eq([10])
    end

    it 'handles stages that emit nothing' do
      stage = described_class.new(name: :my_pipeline)
      pipeline = Minigun::Pipeline.new(:test, config)
      stage.pipeline = pipeline

      # Stage that never emits
      pipeline.add_stage(:processor, :black_hole) { |_item| nil }

      context = Object.new
      result = stage.execute_with_emit(context, 5)

      expect(result).to eq([])
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

      pipeline.add_stage(:processor, :track_and_double) do |item|
        tracking << "saw #{item}"
        emit(item * 2)
      end

      result = stage.execute_with_emit(context, 5)

      expect(result).to eq([10])
      expect(context.tracking).to eq(["saw 5"])
    end
  end
end

