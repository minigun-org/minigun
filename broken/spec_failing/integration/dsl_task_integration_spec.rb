# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'DSL and Task Integration' do
  # Define a test class using the Minigun::DSL
  class TestTask
    include Minigun::DSL

    # Track class variables
    @@consumed_batches = []
    @@before_run_called = false
    @@after_run_called = false

    class << self
      def consumed_batches
        @@consumed_batches
      end

      def consumed_batches=(val)
        @@consumed_batches = val
      end

      def before_run_called
        @@before_run_called
      end

      def before_run_called=(val)
        @@before_run_called = val
      end

      def after_run_called
        @@after_run_called
      end

      def after_run_called=(val)
        @@after_run_called = val
      end

      def hooks_called?
        @@before_run_called && @@after_run_called
      end

      def reset!
        @@consumed_batches = []
        @@before_run_called = false
        @@after_run_called = false
      end
    end

    # Configure the task
    max_threads 2
    max_processes 1
    batch_size 3
    fork_mode :never
    consumer_type :ipc

    # Define stages
    producer :source do
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

    consumer :sink do |batch|
      # Just consume the batch
      TestTask.consumed_batches ||= []
      TestTask.consumed_batches << batch
    end

    # Add hooks
    before_run do
      puts 'Before run hook: setting @@before_run_called to true'
      @@before_run_called = true
      TestTask.before_run_called = true
    end

    after_run do
      puts 'After run hook: setting @@after_run_called to true'
      @@after_run_called = true
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

      # Check the connections
      expect(task.connections).to have_key(:source)
      expect(task.connections[:source]).to include(:double)
      expect(task.connections[:double]).to include(:add_one)
      expect(task.connections[:add_one]).to include(:collect)
      expect(task.connections[:collect]).to include(:sink)

      # Check specific options on stages
      source_options = task.pipeline.find { |s| s[:name] == :source }[:options]
      expect(source_options).to be_a(Hash)

      accumulator_options = task.pipeline.find { |s| s[:name] == :collect }[:options]
      expect(accumulator_options).to be_a(Hash)
      expect(accumulator_options[:batch_size]).to eq(3)

      # Run the task
      instance = TestTask.new
      instance.run

      # Verify the hooks were called
      expect(TestTask.hooks_called?).to be true

      # Verify results - should get batches of converted numbers
      # Because we've run the pipeline with fork_mode: never, the results
      # will be automatically passed to the consumer
      expect(TestTask.consumed_batches).not_to be_empty

      # Aggregate all consumed items across batches
      all_consumed_items = TestTask.consumed_batches.flatten

      # Input: [1, 2, 3, 4, 5]
      # After double: [2, 4, 6, 8, 10]
      # After add_one: [3, 5, 7, 9, 11]
      expected_items = [3, 5, 7, 9, 11]

      # Verify each expected item is in the consumed items
      expected_items.each do |item|
        expect(all_consumed_items).to include(item)
      end

      # Verify we have the right number of items
      expect(all_consumed_items.length).to eq(expected_items.length)
    end
  end

  describe 'running a task with a custom context' do
    # Define a custom context class
    class CustomContext
      attr_reader :results

      def initialize
        @results = []
      end

      def add_result(result)
        @results << result
      end
    end

    # Define a module using the DSL with a custom context
    module CustomTaskWithContext
      include Minigun::DSL

      # Configure the task
      fork_mode :never
      batch_size 3

      # Define stages
      producer :source do
        [10, 20, 30].each { |i| emit(i) }
      end

      processor :multiply do |num|
        emit(num * 2)
      end

      accumulator :collector, batch_size: 2 do |item|
        # Access the context to store results
        @context.add_result(item)

        # Need to emit explicitly in custom accumulator block
        emit_to_queue(:default, item)

        # We'll manually flush for testing with fork_mode=:never
        if @pipeline&.task && @pipeline.task.config[:fork_mode] == :never && respond_to?(:flush)
          # Force flush in test mode
          # This ensures the next stages get our items
          flush
        end
      end

      consumer :sink do |batch|
        # Store the batch in the context
        @context.add_result(batch)
      end
    end

    it 'correctly runs with a custom context' do
      # Create a custom context to pass to the task
      context = CustomContext.new

      # Verify the pipeline structure
      task = CustomTaskWithContext._minigun_task
      expect(task.pipeline.size).to eq(4)

      # Verify the modules were properly set up
      stages = task.pipeline.map { |s| [s[:type], s[:name]] }
      expected_stages = [
        %i[processor source],
        %i[processor multiply],
        %i[accumulator collector],
        %i[processor sink]
      ]
      expect(stages).to eq(expected_stages)

      # Run the task with our custom context
      CustomTaskWithContext.run(context)

      # Verify context contains the processed results
      # Input: [10, 20, 30] -> multiply -> [20, 40, 60]
      # The collector accumulates and the sink consumes them
      results = context.results.flatten

      # Each item should be processed and then batched
      [20, 40, 60].each do |expected|
        expect(results).to include(expected)
      end
    end
  end
end
