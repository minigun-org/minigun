# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Minigun::Runner do
  let(:task_class) do
    Class.new do
      include Minigun::Task

      attr_reader :producer_called, :processor_called, :consumer_called
      attr_reader :producer_items, :processor_items, :consumer_batches

      def initialize
        @producer_called = 0
        @processor_called = 0
        @consumer_called = 0
        @producer_items = []
        @processor_items = []
        @consumer_batches = []
      end

      producer do
        @producer_called += 1
        items = [1, 2, 3]
        @producer_items = items.dup
        produce(items)
      end

      processor do |item|
        @processor_called += 1
        @processor_items << item
        emit(item * 2)
      end

      consumer do |batch|
        @consumer_called += 1
        @consumer_batches << batch
      end

      # Configure task for testing
      batch_size 2
      max_threads 1
      max_processes 1
      fork_mode :never
    end
  end

  let(:task) { task_class.new }
  let(:runner) { described_class.new(task) }

  describe '#initialize' do
    it 'initializes a new runner with the task' do
      expect(runner.instance_variable_get(:@task)).to eq(task)
      expect(runner.instance_variable_get(:@config)).to be_a(Hash)
    end

    it 'sets up job ID and configuration' do
      expect(runner.job_id).to be_a(String)
      expect(runner.job_id.size).to eq(8)
      expect(runner.instance_variable_get(:@max_threads)).to eq(1)
      expect(runner.instance_variable_get(:@max_processes)).to eq(1)
      expect(runner.instance_variable_get(:@fork_mode)).to eq(:never)
    end
  end

  describe '#run' do
    it 'calls hooks on the task when run' do
      # Mock the core methods to prevent actual execution
      allow(runner).to receive(:run_producer)
      allow(runner).to receive(:run_accumulator)
      allow(runner).to receive(:wait_all_consumer_processes)

      # Mock futures to avoid asynchronous execution
      producer_future = instance_double(Concurrent::Future, wait: nil, rejected?: false)
      accumulator_future = instance_double(Concurrent::Future, wait: nil, rejected?: false)
      allow(Concurrent::Future).to receive(:execute).and_return(producer_future, accumulator_future)

      # Expect the hooks to be called
      expect(task).to receive(:run_hooks).with(:before_run)
      expect(task).to receive(:run_hooks).with(:after_run)

      runner.run
    end
  end
end
