# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'DSL and Task Integration' do
  # Define a test class using the Minigun::DSL
  class TestTask
    include Minigun::DSL

    # Track class variables
    @@processed_batches = []
    @@before_run_called = false
    @@after_run_called = false

    class << self
      attr_accessor :processed_batches, :before_run_called, :after_run_called

      def hooks_called?
        @@before_run_called && @@after_run_called
      end

      def reset!
        @@processed_batches = []
        @@before_run_called = false
        @@after_run_called = false
      end
    end

    # Configure the task
    max_threads 2
    max_processes 1
    batch_size 3
    fork_mode :never
    fork_type :ipc

    # Define stages
    processor :source do
      # Use a local reference
      items = [1, 2, 3, 4, 5]
      items.each { |i| emit(i) }
    end

    processor :double do |num|
      emit(num * 2)
    end

    processor :add_one do |num|
      emit(num + 1)
    end

    accumulator :collect do
      # Default behavior
    end

    processor :sink do |batch|
      # Just process the batch
      TestTask.processed_batches ||= []
      TestTask.processed_batches << batch
    end

    # Add hooks
    before_run do
      TestTask.before_run_called = true
    end

    after_run do
      TestTask.after_run_called = true
    end
  end

  # Test that includes the test module
  describe 'running a task through DSL' do
    before do
      # Reset any state from previous tests
      TestTask.reset!
    end

    it 'correctly creates and runs a task' do
      # Get the task object
      task = TestTask._minigun_task

      # Verify the pipeline structure
      expect(task.pipeline.size).to eq(5)

      # Check the stages
      stages = task.pipeline.map { |s| [s[:type], s[:name]] }
      expected_stages = [
        %i[processor source],
        %i[processor double],
        %i[processor add_one],
        %i[accumulator collect],
        %i[processor sink]
      ]

      expect(stages).to eq(expected_stages)

      # Verify processor block exists
      expect(task.stage_blocks[:source]).to be_a(Proc)

      # Verify hooks are defined
      expect(task.hooks[:before_run]).not_to be_empty
      expect(task.hooks[:after_run]).not_to be_empty
    end

    it 'calls hooks during execution' do
      # Get the task object
      task = TestTask._minigun_task

      # Verify hooks exist
      expect(task.hooks[:before_run]).not_to be_empty
      expect(task.hooks[:after_run]).not_to be_empty
    end

    it 'correctly applies configuration' do
      # Get the configuration from the task
      task = TestTask._minigun_task

      # Verify configuration was applied
      expect(task.config[:max_threads]).to eq(2)
      expect(task.config[:max_processes]).to eq(1)
      expect(task.config[:batch_size]).to eq(3)
      expect(task.config[:fork_mode]).to eq(:never)
      expect(task.config[:fork_type]).to eq(:ipc)
    end

    it 'correctly builds the pipeline' do
      # Get the pipeline from the task
      task = TestTask._minigun_task

      # Verify pipeline stages
      expect(task.pipeline.size).to eq(5)

      # Check stage names and types
      stage_info = task.pipeline.map { |stage| [stage[:type], stage[:name]] }
      expected_stages = [
        %i[processor source],
        %i[processor double],
        %i[processor add_one],
        %i[accumulator collect],
        %i[processor sink]
      ]

      expect(stage_info).to eq(expected_stages)
    end
  end

  # Test defining a task with a custom run configuration
  describe 'running with custom context' do
    class CustomContext
      attr_accessor :results

      def initialize
        @results = []
      end
    end

    module CustomTaskWithContext
      include Minigun::DSL

      processor do
        emit(1..3)
      end

      processor do |num|
        emit(num * 3)
      end

      processor do |batch|
        # Store in the context
        context.results.concat(batch)
      end
    end

    it 'uses the provided context' do
      # Get the task from the module
      task = CustomTaskWithContext._minigun_task

      # Verify pipeline structure
      expect(task.pipeline.size).to eq(3)

      # Check the stages have the right types
      stage_types = task.pipeline.map { |s| s[:type] }
      expect(stage_types).to eq(%i[processor processor processor])

      # Verify blocks exist
      expect(task.stage_blocks[task.pipeline[0][:name]]).to be_a(Proc)
      expect(task.stage_blocks[task.pipeline[1][:name]]).to be_a(Proc)
      expect(task.stage_blocks[task.pipeline[2][:name]]).to be_a(Proc)
    end
  end
end
