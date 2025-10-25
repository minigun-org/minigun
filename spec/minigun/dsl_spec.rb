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
      expect(test_class._task.config[:max_threads]).to eq(10)
    end

    it 'provides max_processes configuration' do
      test_class.max_processes 4
      expect(test_class._task.config[:max_processes]).to eq(4)
    end

    it 'provides max_retries configuration' do
      test_class.max_retries 5
      expect(test_class._task.config[:max_retries]).to eq(5)
    end

    it 'allows defining a producer' do
      test_class.producer(:test_producer) { "producer code" }
      expect(test_class._task.stages[:producer]).not_to be_nil
      expect(test_class._task.stages[:producer][:name]).to eq(:test_producer)
    end

    it 'allows defining processors' do
      test_class.processor(:test_processor) { "processor code" }
      expect(test_class._task.stages[:processor]).to be_an(Array)
      expect(test_class._task.stages[:processor].first[:name]).to eq(:test_processor)
    end

    it 'allows defining an accumulator' do
      test_class.accumulator(:test_accumulator) { "accumulator code" }
      expect(test_class._task.stages[:accumulator]).not_to be_nil
      expect(test_class._task.stages[:accumulator][:name]).to eq(:test_accumulator)
    end

    it 'allows defining a consumer' do
      test_class.consumer(:test_consumer) { "consumer code" }
      expect(test_class._task.stages[:consumer]).not_to be_nil
      expect(test_class._task.stages[:consumer][:name]).to eq(:test_consumer)
    end

    it 'allows defining cow_fork as alias for consumer' do
      test_class.cow_fork(:test_fork) { "fork code" }
      expect(test_class._task.stages[:consumer]).not_to be_nil
      expect(test_class._task.stages[:consumer][:name]).to eq(:test_fork)
    end

    it 'allows defining ipc_fork as alias for consumer' do
      test_class.ipc_fork(:test_ipc) { "ipc code" }
      expect(test_class._task.stages[:consumer]).not_to be_nil
      expect(test_class._task.stages[:consumer][:name]).to eq(:test_ipc)
    end

    it 'allows defining before_run hook' do
      test_class.before_run { "before run" }
      expect(test_class._task.hooks[:before_run]).not_to be_empty
    end

    it 'allows defining after_run hook' do
      test_class.after_run { "after run" }
      expect(test_class._task.hooks[:after_run]).not_to be_empty
    end

    it 'allows defining before_fork hook' do
      test_class.before_fork { "before fork" }
      expect(test_class._task.hooks[:before_fork]).not_to be_empty
    end

    it 'allows defining after_fork hook' do
      test_class.after_fork { "after fork" }
      expect(test_class._task.hooks[:after_fork]).not_to be_empty
    end

    it 'allows defining pipeline block for grouping' do
      test_class.pipeline do
        producer(:grouped_producer) { "code" }
        consumer(:grouped_consumer) { "code" }
      end

      expect(test_class._task.stages[:producer][:name]).to eq(:grouped_producer)
      expect(test_class._task.stages[:consumer][:name]).to eq(:grouped_consumer)
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
      task = test_class._task

      expect(task.config[:max_threads]).to eq(3)
      expect(task.config[:max_processes]).to eq(2)
      expect(task.stages[:producer]).not_to be_nil
      expect(task.stages[:processor].size).to eq(1)
      expect(task.stages[:consumer]).not_to be_nil
      expect(task.hooks[:before_run].size).to eq(1)
      expect(task.hooks[:after_run].size).to eq(1)
    end
  end
end

