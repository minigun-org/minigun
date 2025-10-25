# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Minigun::DSL do
  describe 'class methods' do
    let(:test_class) do
      Class.new do
        include Minigun::DSL
      end
    end

    it 'provides max_threads configuration' do
      test_class.max_threads 10
      expect(test_class._minigun_task.config[:max_threads]).to eq(10)
    end

    it 'provides max_processes configuration' do
      test_class.max_processes 4
      expect(test_class._minigun_task.config[:max_processes]).to eq(4)
    end

    it 'provides max_retries configuration' do
      test_class.max_retries 5
      expect(test_class._minigun_task.config[:max_retries]).to eq(5)
    end

    it 'allows defining a producer' do
      test_class.producer(:test_producer) { "producer code" }
      expect(test_class._minigun_task.stages[:producer]).not_to be_nil
      expect(test_class._minigun_task.stages[:producer][:name]).to eq(:test_producer)
    end

    it 'allows defining processors' do
      test_class.processor(:test_processor) { "processor code" }
      expect(test_class._minigun_task.stages[:processor]).to be_an(Array)
      expect(test_class._minigun_task.stages[:processor].first[:name]).to eq(:test_processor)
    end

    it 'allows defining an accumulator' do
      test_class.accumulator(:test_accumulator) { "accumulator code" }
      expect(test_class._minigun_task.stages[:accumulator]).not_to be_nil
      expect(test_class._minigun_task.stages[:accumulator][:name]).to eq(:test_accumulator)
    end

    it 'allows defining a consumer' do
      test_class.consumer(:test_consumer) { "consumer code" }
      expect(test_class._minigun_task.stages[:consumer]).not_to be_empty
      expect(test_class._minigun_task.stages[:consumer][0][:name]).to eq(:test_consumer)
    end

    it 'allows defining cow_fork as alias for consumer' do
      test_class.cow_fork(:test_fork) { "fork code" }
      expect(test_class._minigun_task.stages[:consumer]).not_to be_empty
      expect(test_class._minigun_task.stages[:consumer][0][:name]).to eq(:test_fork)
    end

    it 'allows defining ipc_fork as alias for consumer' do
      test_class.ipc_fork(:test_ipc) { "ipc code" }
      expect(test_class._minigun_task.stages[:consumer]).not_to be_empty
      expect(test_class._minigun_task.stages[:consumer][0][:name]).to eq(:test_ipc)
    end

    it 'allows defining before_run hook' do
      test_class.before_run { "before run" }
      expect(test_class._minigun_task.hooks[:before_run]).not_to be_empty
    end

    it 'allows defining after_run hook' do
      test_class.after_run { "after run" }
      expect(test_class._minigun_task.hooks[:after_run]).not_to be_empty
    end

    it 'allows defining before_fork hook' do
      test_class.before_fork { "before fork" }
      expect(test_class._minigun_task.hooks[:before_fork]).not_to be_empty
    end

    it 'allows defining after_fork hook' do
      test_class.after_fork { "after fork" }
      expect(test_class._minigun_task.hooks[:after_fork]).not_to be_empty
    end

    it 'allows defining pipeline block for grouping' do
      test_class.pipeline do
        producer(:grouped_producer) { "code" }
        consumer(:grouped_consumer) { "code" }
      end

      expect(test_class._minigun_task.stages[:producer][:name]).to eq(:grouped_producer)
      expect(test_class._minigun_task.stages[:consumer][0][:name]).to eq(:grouped_consumer)
    end
  end

  describe 'instance methods' do
    let(:test_class) do
      Class.new do
        include Minigun::DSL

        producer(:test_producer) do
          5.times { |i| emit(i) }
        end

        consumer(:test_consumer) do |item|
          @processed ||= []
          @processed << item
        end
      end
    end

    let(:instance) { test_class.new }

    it 'provides run method' do
      expect(instance).to respond_to(:run)
    end

    it 'provides go_brrr! alias' do
      expect(instance).to respond_to(:go_brrr!)
    end
  end

  describe 'full pipeline definition' do
    let(:test_class) do
      Class.new do
        include Minigun::DSL

        max_threads 3
        max_processes 2

        pipeline do
          producer :generate do
            3.times { |i| emit(i + 1) }
          end

          processor :double do |num|
            emit(num * 2)
          end

          consumer :collect do |num|
            @results ||= []
            @results << num
          end
        end

        before_run { @start_time = Time.now }
        after_run { @end_time = Time.now }
      end
    end

    it 'correctly configures all components' do
      task = test_class._minigun_task

      expect(task.config[:max_threads]).to eq(3)
      expect(task.config[:max_processes]).to eq(2)
      expect(task.stages[:producer]).not_to be_nil
      expect(task.stages[:processor].size).to eq(1)
      expect(task.stages[:consumer]).not_to be_nil
      expect(task.hooks[:before_run].size).to eq(1)
      expect(task.hooks[:after_run].size).to eq(1)
    end
  end

  describe 'implicit pipeline definition (without pipeline block)' do
    before do
      allow(Minigun.logger).to receive(:info)
    end

    it 'allows defining stages without pipeline block wrapper' do
      # Define pipeline WITHOUT explicit pipeline block
      pipeline_class = Class.new do
        include Minigun::DSL

        attr_accessor :results

        def initialize
          @results = []
        end

        # No pipeline do...end wrapper!
        producer :generate do
          3.times { |i| emit(i + 1) }
        end

        processor :double do |num|
          emit(num * 2)
        end

        consumer :collect do |num|
          results << num
        end
      end

      pipeline = pipeline_class.new
      pipeline.run

      expect(pipeline.results).to contain_exactly(2, 4, 6)
    end

    it 'works identically with or without pipeline block' do
      # WITH pipeline block
      with_block = Class.new do
        include Minigun::DSL
        attr_accessor :results

        def initialize
          @results = []
        end

        pipeline do
          producer :source do
            5.times { |i| emit(i) }
          end

          consumer :sink do |num|
            results << num
          end
        end
      end

      # WITHOUT pipeline block
      without_block = Class.new do
        include Minigun::DSL
        attr_accessor :results

        def initialize
          @results = []
        end

        producer :source do
          5.times { |i| emit(i) }
        end

        consumer :sink do |num|
          results << num
        end
      end

      with_result = with_block.new
      with_result.run

      without_result = without_block.new
      without_result.run

      expect(with_result.results.sort).to eq(without_result.results.sort)
      expect(with_result.results).to contain_exactly(0, 1, 2, 3, 4)
      expect(without_result.results).to contain_exactly(0, 1, 2, 3, 4)
    end

    it 'supports mixing both styles' do
      mixed_class = Class.new do
        include Minigun::DSL
        attr_accessor :results

        def initialize
          @results = []
        end

        # Some stages outside pipeline block
        producer :start do
          emit(10)
        end

        # Some stages inside pipeline block
        pipeline do
          processor :multiply do |n|
            emit(n * 3)
          end

          consumer :finish do |n|
            results << n
          end
        end
      end

      pipeline = mixed_class.new
      pipeline.run

      expect(pipeline.results).to eq([30])
    end

    it 'can define complex routing without pipeline block' do
      routing_class = Class.new do
        include Minigun::DSL
        attr_accessor :path_a_results, :path_b_results

        def initialize
          @path_a_results = []
          @path_b_results = []
          @mutex = Mutex.new
        end

        producer :start, to: [:process_a, :process_b] do
          emit(5)
        end

        consumer :process_a do |n|
          @mutex.synchronize { path_a_results << n * 2 }
        end

        consumer :process_b do |n|
          @mutex.synchronize { path_b_results << n * 3 }
        end
      end

      pipeline = routing_class.new
      pipeline.run

      expect(pipeline.path_a_results).to eq([10])
      expect(pipeline.path_b_results).to eq([15])
    end

    it 'supports all stage types without pipeline block' do
      full_class = Class.new do
        include Minigun::DSL
        attr_accessor :results

        def initialize
          @results = []
        end

        # Direct definition - no pipeline block needed
        producer :fetch do
          emit(1)
          emit(2)
        end

        processor :validate do |n|
          emit(n) if n > 0
        end

        processor :transform do |n|
          emit(n * 10)
        end

        consumer :save do |n|
          results << n
        end

        before_run { @results << :started }
        after_run { @results << :finished }
      end

      pipeline = full_class.new
      pipeline.run

      expect(pipeline.results).to include(:started, 10, 20, :finished)
    end
  end
end

