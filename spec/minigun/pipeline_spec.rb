# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Minigun::Pipeline do
  let(:config) { { max_threads: 3, max_processes: 2 } }
  let(:pipeline) { Minigun::Pipeline.new(:test_pipeline, config) }

  describe '#initialize' do
    it 'creates a pipeline with a name' do
      expect(pipeline.name).to eq(:test_pipeline)
    end

    it 'accepts configuration options' do
      expect(pipeline.config[:max_threads]).to eq(3)
      expect(pipeline.config[:max_processes]).to eq(2)
    end

    it 'uses default config for missing options' do
      default_pipeline = Minigun::Pipeline.new(:default)
      expect(default_pipeline.config[:max_threads]).to eq(5)
    end

    it 'initializes empty stages' do
      expect(pipeline.stages[:producer]).to be_nil
      expect(pipeline.stages[:processor]).to eq([])
      expect(pipeline.stages[:consumer]).to eq([])
    end

    it 'initializes a DAG for stage routing' do
      expect(pipeline.dag).to be_a(Minigun::DAG)
    end
  end

  describe '#add_stage' do
    it 'adds a producer stage' do
      pipeline.add_stage(:producer, :fetch) { "fetch data" }
      expect(pipeline.stages[:producer]).to be_a(Minigun::ProducerStage)
      expect(pipeline.stages[:producer].name).to eq(:fetch)
    end

    it 'adds multiple processor stages' do
      pipeline.add_stage(:processor, :transform) { |item| item }
      pipeline.add_stage(:processor, :validate) { |item| item }
      expect(pipeline.stages[:processor].size).to eq(2)
    end

    it 'adds a consumer stage' do
      pipeline.add_stage(:consumer, :save) { |item| puts item }
      expect(pipeline.stages[:consumer].size).to eq(1)
    end

    it 'handles stage routing with :to option' do
      pipeline.add_stage(:producer, :source, to: :transform) { "data" }
      pipeline.add_stage(:processor, :transform, to: :save) { |item| item }
      pipeline.add_stage(:consumer, :save) { |item| puts item }

      expect(pipeline.dag.downstream(:source)).to include(:transform)
      expect(pipeline.dag.downstream(:transform)).to include(:save)
    end
  end

  describe '#add_hook' do
    it 'adds before_run hooks' do
      pipeline.add_hook(:before_run) { puts "starting" }
      expect(pipeline.hooks[:before_run].size).to eq(1)
    end

    it 'adds multiple hooks of the same type' do
      pipeline.add_hook(:before_run) { puts "hook 1" }
      pipeline.add_hook(:before_run) { puts "hook 2" }
      expect(pipeline.hooks[:before_run].size).to eq(2)
    end
  end

  describe '#input_queue=' do
    it 'sets an input queue for inter-pipeline communication' do
      queue = SizedQueue.new(10)
      pipeline.input_queue = queue
      expect(pipeline.input_queue).to eq(queue)
    end
  end

  describe '#add_output_queue' do
    it 'adds an output queue for downstream pipeline' do
      queue = SizedQueue.new(10)
      pipeline.add_output_queue(:next_pipeline, queue)
      expect(pipeline.output_queues[:next_pipeline]).to eq(queue)
    end

    it 'supports multiple output queues' do
      queue1 = SizedQueue.new(10)
      queue2 = SizedQueue.new(10)
      pipeline.add_output_queue(:pipeline_a, queue1)
      pipeline.add_output_queue(:pipeline_b, queue2)
      expect(pipeline.output_queues.size).to eq(2)
    end
  end

  describe '#run' do
    before do
      allow(Minigun.logger).to receive(:info)
    end

    it 'executes a simple pipeline' do
      context = Class.new do
        attr_accessor :results
        def initialize
          @results = []
        end
      end.new

      pipeline.add_stage(:producer, :source) do
        emit(1)
        emit(2)
      end

      pipeline.add_stage(:consumer, :sink) do |item|
        results << item
      end

      pipeline.run(context)
      expect(context.results).to contain_exactly(1, 2)
    end

    it 'executes hooks in order' do
      context = Class.new do
        attr_accessor :events
        def initialize
          @events = []
        end
      end.new

      pipeline.add_hook(:before_run) { events << :before }
      pipeline.add_hook(:after_run) { events << :after }

      pipeline.add_stage(:producer, :source) { emit(1) }
      pipeline.add_stage(:consumer, :sink) { |item| events << :process }

      pipeline.run(context)
      expect(context.events.first).to eq(:before)
      expect(context.events.last).to eq(:after)
      expect(context.events).to include(:process)
    end

    it 'processes items through processors' do
      context = Class.new do
        attr_accessor :results
        def initialize
          @results = []
        end
      end.new

      pipeline.add_stage(:producer, :source) do
        emit(5)
      end

      pipeline.add_stage(:processor, :double) do |item|
        emit(item * 2)
      end

      pipeline.add_stage(:consumer, :sink) do |item|
        results << item
      end

      pipeline.run(context)
      expect(context.results).to eq([10])
    end
  end

  describe '#run_in_thread' do
    before do
      allow(Minigun.logger).to receive(:info)
    end

    it 'returns a thread' do
      context = Class.new do
        attr_accessor :results
        def initialize
          @results = []
        end
      end.new

      pipeline.add_stage(:producer, :source) { emit(1) }
      pipeline.add_stage(:consumer, :sink) { |item| results << item }

      thread = pipeline.run_in_thread(context)
      expect(thread).to be_a(Thread)
      thread.join
    end

    it 'executes pipeline asynchronously' do
      context = Class.new do
        attr_accessor :results
        def initialize
          @results = []
        end
      end.new

      pipeline.add_stage(:producer, :source) do
        3.times { |i| emit(i) }
      end

      pipeline.add_stage(:consumer, :sink) do |item|
        results << item
      end

      thread = pipeline.run_in_thread(context)
      thread.join

      expect(context.results).to contain_exactly(0, 1, 2)
    end
  end
end

