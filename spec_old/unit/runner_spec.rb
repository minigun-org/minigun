# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Minigun::Runner do
  let(:task) do
    task = Minigun::Task.new

    # Add instance variables for tracking
    task.instance_variable_set(:@source_called, 0)
    task.instance_variable_set(:@processor_called, 0)
    task.instance_variable_set(:@sink_called, 0)
    task.instance_variable_set(:@source_items, [])
    task.instance_variable_set(:@processor_items, [])
    task.instance_variable_set(:@sink_batches, [])

    # Add methods for testing
    def task.source_called
      @source_called
    end

    def task.processor_called
      @processor_called
    end

    def task.sink_called
      @sink_called
    end

    def task.source_items
      @source_items
    end

    def task.processor_items
      @processor_items
    end

    def task.sink_batches
      @sink_batches
    end

    # Add processor stages for each role
    task.add_processor(:source_processor, {}) do
      @source_called += 1
      items = [1, 2, 3]
      @source_items = items.dup
      emit(items)
    end

    task.add_processor(:test_processor, {}) do |item|
      @processor_called += 1
      @processor_items << item
      emit(item * 2)
    end

    task.add_processor(:sink_processor, {}) do |batch|
      @sink_called += 1
      @sink_batches << batch
    end

    # Configure task for testing
    task.config[:batch_size] = 2
    task.config[:max_threads] = 1
    task.config[:max_processes] = 1
    task.config[:fork_mode] = :never

    task
  end

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
      allow(runner).to receive(:run_processor)
      allow(runner).to receive(:run_accumulator)
      allow(runner).to receive(:wait_all_processor_processes)

      # Mock futures to avoid asynchronous execution
      processor_future = instance_double(Concurrent::Future, wait: nil, rejected?: false)
      accumulator_future = instance_double(Concurrent::Future, wait: nil, rejected?: false)
      allow(Concurrent::Future).to receive(:execute).and_return(processor_future, accumulator_future)

      # Expect the hooks to be called
      expect(task).to receive(:run_hooks).with(:before_run, task)
      expect(task).to receive(:run_hooks).with(:after_run, task)

      runner.run
    end
  end
end
