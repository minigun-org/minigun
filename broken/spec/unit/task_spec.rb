# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Minigun::Task do
  subject { task }

  let(:task) { described_class.new }

  describe 'initialization' do
    it 'initializes with default configuration' do
      expect(task.config[:max_threads]).to eq(5)
      expect(task.config[:max_processes]).to eq(2)
      expect(task.config[:max_retries]).to eq(3)
      expect(task.config[:batch_size]).to eq(100)
      expect(task.config[:fork_mode]).to eq(:auto)
      expect(task.config[:fork_type]).to eq(:ipc)
    end

    it 'initializes with empty stage blocks' do
      expect(task.stage_blocks).to be_empty
    end

    it 'initializes with empty pipeline' do
      expect(task.pipeline).to be_empty
    end

    it 'initializes with empty accumulated items array' do
      expect(task.accumulated_items).to be_an(Array)
      expect(task.accumulated_items).to be_empty
    end

    it 'initializes with default hooks' do
      expected_hooks = %i[
        before_run after_run before_fork after_fork
        after_producer_finished after_consumer_finished
      ]
      expected_hooks.each do |hook|
        expect(task.hooks).to have_key(hook)
        expect(task.hooks[hook]).to be_an(Array)
        expect(task.hooks[hook]).to be_empty
      end
    end
  end

  describe 'stage definition methods' do
    it 'adds a producer to the pipeline' do
      task = described_class.new
      task.add_producer(:test_producer)

      expect(task.pipeline.size).to eq(1)
      expect(task.pipeline.first[:type]).to eq(:processor)
      expect(task.pipeline.first[:name]).to eq(:test_producer)
    end

    it 'adds a processor to the pipeline' do
      processor_block = proc { |item| puts "processing #{item}" }
      task.add_processor(:test_processor, {}, &processor_block)

      expect(task.stage_blocks[:test_processor]).to eq(processor_block)
      expect(task.pipeline.size).to eq(1)
      expect(task.pipeline.first[:type]).to eq(:processor)
      expect(task.pipeline.first[:name]).to eq(:test_processor)
      expect(task.pipeline.first[:options][:is_producer]).to be_nil
    end

    it 'adds an accumulator to the pipeline' do
      accumulator_block = proc { |item| puts "accumulating #{item}" }
      task.add_accumulator(:test_accumulator, {}, &accumulator_block)

      expect(task.stage_blocks[:test_accumulator]).to eq(accumulator_block)
      expect(task.pipeline.size).to eq(1)
      expect(task.pipeline.first[:type]).to eq(:accumulator)
      expect(task.pipeline.first[:name]).to eq(:test_accumulator)
    end

    it 'adds a consumer to the pipeline' do
      consumer_block = proc { |batch| puts "consuming #{batch}" }
      task.add_consumer(:test_consumer, {}, &consumer_block)

      expect(task.stage_blocks[:test_consumer]).to eq(consumer_block)
      expect(task.pipeline.size).to eq(1)
      expect(task.pipeline.first[:type]).to eq(:processor)
      expect(task.pipeline.first[:name]).to eq(:test_consumer)
      expect(task.pipeline.first[:options][:is_producer]).to be_nil
    end

    it 'adds a cow_fork consumer to the pipeline' do
      fork_block = proc { |batch| puts "cow forking #{batch}" }
      task.add_consumer(:test_fork, { fork: :cow }, &fork_block)

      expect(task.stage_blocks[:test_fork]).to eq(fork_block)
      expect(task.pipeline.size).to eq(1)
      expect(task.pipeline.first[:type]).to eq(:cow_fork)
      expect(task.pipeline.first[:name]).to eq(:test_fork)
    end

    it 'supports the new generic add_stage method' do
      stage_block = proc { |item| item }
      task.add_stage(:processor, :generic_stage, { some_option: true }, &stage_block)

      expect(task.stage_blocks[:generic_stage]).to eq(stage_block)
      expect(task.pipeline.size).to eq(1)
      expect(task.pipeline.first[:type]).to eq(:processor)
      expect(task.pipeline.first[:name]).to eq(:generic_stage)
      expect(task.pipeline.first[:options][:some_option]).to be(true)
    end
  end

  describe 'hook methods' do
    it 'adds a hook' do
      hook_block = proc { puts 'running hook' }
      task.add_hook(:before_run, {}, &hook_block)

      expect(task.hooks[:before_run].size).to eq(1)
      expect(task.hooks[:before_run].first[:block]).to eq(hook_block)
    end

    it 'runs hooks with conditions' do
      context_obj = Object.new
      context_obj.instance_variable_set(:@condition_var, false)

      def context_obj.condition_var
        @condition_var ||= false
      end

      def context_obj.condition_var=(val)
        @condition_var = val
      end

      # Add hooks that capture their execution
      executed_hooks = []

      # Add a hook with an if condition
      if_hook = proc { executed_hooks << :if_hook }
      task.add_hook(:before_run, { if: proc { condition_var } }, &if_hook)

      # Add a hook with an unless condition
      unless_hook = proc { executed_hooks << :unless_hook }
      task.add_hook(:before_run, { unless: proc { condition_var } }, &unless_hook)

      # Run the hooks with condition_var = false
      task.run_hooks(:before_run, context_obj)

      # Verify that only the unless hook ran
      expect(executed_hooks).to eq([:unless_hook])

      # Reset executed hooks
      executed_hooks.clear

      # Set condition_var to true and run hooks again
      context_obj.condition_var = true
      task.run_hooks(:before_run, context_obj)

      # Verify that only the if hook ran
      expect(executed_hooks).to eq([:if_hook])
    end
  end

  describe 'connection options' do
    it 'processes from connections' do
      task.process_connection_options(:target, { from: :source })

      expect(task.connections[:source]).to include(:target)
    end

    it 'processes to connections' do
      task.process_connection_options(:source, { to: :target })

      expect(task.connections[:source]).to eq([:target])
    end

    it 'processes queue subscriptions' do
      task.process_connection_options(:consumer, { queues: %i[high_priority low_priority] })

      expect(task.queue_subscriptions[:consumer]).to eq(%i[high_priority low_priority])
    end
  end

  describe 'stage options' do
    it 'applies accumulator-specific options' do
      options = {}
      task.add_stage(:accumulator, :test_accumulator, options)
      stage_options = task.pipeline.first[:options]

      expect(stage_options[:batch_size]).to eq(task.config[:batch_size])
      expect(stage_options[:flush_interval]).to be_a(Float)
    end

    it 'applies processor-specific options' do
      options = {}
      task.add_stage(:processor, :test_processor, options)
      stage_options = task.pipeline.first[:options]

      expect(stage_options[:max_threads]).to eq(task.config[:max_threads])
      expect(stage_options[:threads]).to eq(task.config[:max_threads])
      expect(stage_options[:max_retries]).to eq(task.config[:max_retries])
    end

    it 'applies cow_fork-specific options' do
      options = {}
      task.add_stage(:cow_fork, :test_fork, options)
      stage_options = task.pipeline.first[:options]

      expect(stage_options[:fork]).to eq(:cow)
      expect(stage_options[:type]).to eq(:cow)
      expect(stage_options[:max_processes]).to eq(task.config[:max_processes])
      expect(stage_options[:processes]).to eq(task.config[:max_processes])
    end
  end

  describe 'validation' do
    it 'validates placement of stages that require accumulator stages' do
      # Add an accumulator first, then a stage that requires it
      task.add_accumulator(:accumulator)
      task.add_stage(:cow_fork, :consumer)

      # No error should be raised since validation passes
      expect(task.send(:validate_stage_placement, :cow_fork, :consumer)).to be_nil
    end

    it 'warns when a stage should have a prerequisite stage' do
      # Create a temporary class to extend Task for spying
      temp_task = Class.new(described_class) do
        def initialize
          super
          # Initialize pipeline with the test stages
          @pipeline = [
            { type: :processor, name: :source, options: {} },
            { type: :cow_fork, name: :consumer, options: {} }
          ]
          @connections = {}
        end
      end

      # Create an instance with a spy for warn
      task2 = temp_task.new
      allow(task2).to receive(:warn)

      # Call the method directly
      task2.send(:validate_stage_placement, :cow_fork, :consumer)

      # Verify the warning was issued
      expect(task2).to have_received(:warn).with(/COW fork stage consumer should follow an accumulator stage/)
    end
  end

  describe 'running a task' do
    let(:context) { double('context') }

    it 'runs a simple pipeline' do
      # Since we've added a stage to the task, a pipeline will be created instead
      # of a runner, so let's test for that behavior
      pipeline_double = instance_double(Minigun::Pipeline)
      allow(Minigun::Pipeline).to receive(:new).and_return(pipeline_double)
      allow(pipeline_double).to receive_messages(build_pipeline: pipeline_double, run: pipeline_double)
      allow(pipeline_double).to receive(:shutdown)

      # Add a stage to the task
      task.add_stage(:processor, :test)

      # Execute the task's run method and test the pipeline is used
      task.run(context)

      # Verify our pipeline was created and run
      expect(Minigun::Pipeline).to have_received(:new)
      expect(pipeline_double).to have_received(:build_pipeline)
      expect(pipeline_double).to have_received(:run)
      expect(pipeline_double).to have_received(:shutdown)
    end

    it 'runs a custom pipeline' do
      task.pipeline_definition = proc { puts 'defining pipeline' }

      # Create a double for the pipeline
      pipeline_double = instance_double(Minigun::Pipeline)
      allow(Minigun::Pipeline).to receive(:new).with(context, hash_including(custom: true, task: task)).and_return(pipeline_double)
      allow(pipeline_double).to receive_messages(build_pipeline: pipeline_double, run: pipeline_double)
      allow(pipeline_double).to receive(:shutdown)

      # Allow setting instance variables
      allow(pipeline_double).to receive(:instance_variable_set)

      # Run the task
      task.run(context)

      # Verify our expectations
      expect(pipeline_double).to have_received(:build_pipeline)
      expect(pipeline_double).to have_received(:run)
# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Minigun::Task do
  subject { task }

  let(:task) { described_class.new }

  describe 'initialization' do
    it 'initializes with default configuration' do
      expect(task.config[:max_threads]).to eq(5)
      expect(task.config[:max_processes]).to eq(2)
      expect(task.config[:max_retries]).to eq(3)
      expect(task.config[:batch_size]).to eq(100)
      expect(task.config[:fork_mode]).to eq(:auto)
      expect(task.config[:consumer_type]).to eq(:ipc)
    end

    it 'initializes with empty stage blocks' do
      expect(task.stage_blocks).to be_empty
    end

    it 'initializes with empty pipeline' do
      expect(task.pipeline).to be_empty
    end

    it 'initializes with empty accumulated items array' do
      expect(task.accumulated_items).to be_an(Array)
      expect(task.accumulated_items).to be_empty
    end

    it 'initializes with default hooks' do
      expected_hooks = %i[
        before_run after_run before_fork after_fork
        after_producer_finished after_consumer_finished
      ]
      expected_hooks.each do |hook|
        expect(task.hooks).to have_key(hook)
        expect(task.hooks[hook]).to be_an(Array)
        expect(task.hooks[hook]).to be_empty
      end
    end
  end

  describe 'stage definition methods' do
    it 'adds a producer to the pipeline' do
      task = described_class.new
      task.add_producer(:test_producer)

      expect(task.pipeline.size).to eq(1)
      expect(task.pipeline.first[:type]).to eq(:processor)
      expect(task.pipeline.first[:name]).to eq(:test_producer)
    end

    it 'adds a processor to the pipeline' do
      processor_block = proc { |item| puts "processing #{item}" }
      task.add_processor(:test_processor, {}, &processor_block)

      expect(task.stage_blocks[:test_processor]).to eq(processor_block)
      expect(task.pipeline.size).to eq(1)
      expect(task.pipeline.first[:type]).to eq(:processor)
      expect(task.pipeline.first[:name]).to eq(:test_processor)
      expect(task.pipeline.first[:options][:is_producer]).to be_nil
    end

    it 'adds an accumulator to the pipeline' do
      accumulator_block = proc { |item| puts "accumulating #{item}" }
      task.add_accumulator(:test_accumulator, {}, &accumulator_block)

      expect(task.stage_blocks[:test_accumulator]).to eq(accumulator_block)
      expect(task.pipeline.size).to eq(1)
      expect(task.pipeline.first[:type]).to eq(:accumulator)
      expect(task.pipeline.first[:name]).to eq(:test_accumulator)
    end

    it 'adds a consumer to the pipeline' do
      consumer_block = proc { |batch| puts "consuming #{batch}" }
      task.add_consumer(:test_consumer, {}, &consumer_block)

      expect(task.stage_blocks[:test_consumer]).to eq(consumer_block)
      expect(task.pipeline.size).to eq(1)
      expect(task.pipeline.first[:type]).to eq(:processor)
      expect(task.pipeline.first[:name]).to eq(:test_consumer)
      expect(task.pipeline.first[:options][:is_producer]).to be_nil
    end

    it 'adds a cow_fork consumer to the pipeline' do
      fork_block = proc { |batch| puts "cow forking #{batch}" }
      task.add_consumer(:test_fork, { fork: :cow }, &fork_block)

      expect(task.stage_blocks[:test_fork]).to eq(fork_block)
      expect(task.pipeline.size).to eq(1)
      expect(task.pipeline.first[:type]).to eq(:cow_fork)
      expect(task.pipeline.first[:name]).to eq(:test_fork)
    end

    it 'supports the new generic add_stage method' do
      stage_block = proc { |item| item }
      task.add_stage(:processor, :generic_stage, { some_option: true }, &stage_block)

      expect(task.stage_blocks[:generic_stage]).to eq(stage_block)
      expect(task.pipeline.size).to eq(1)
      expect(task.pipeline.first[:type]).to eq(:processor)
      expect(task.pipeline.first[:name]).to eq(:generic_stage)
      expect(task.pipeline.first[:options][:some_option]).to be(true)
    end
  end

  describe 'hook methods' do
    it 'adds a hook' do
      hook_block = proc { puts 'running hook' }
      task.add_hook(:before_run, {}, &hook_block)

      expect(task.hooks[:before_run].size).to eq(1)
      expect(task.hooks[:before_run].first[:block]).to eq(hook_block)
    end

    it 'runs hooks with conditions' do
      context_obj = Object.new
      context_obj.instance_variable_set(:@condition_var, false)

      def context_obj.condition_var
        @condition_var ||= false
      end

      def context_obj.condition_var=(val)
        @condition_var = val
      end

      # Add hooks that capture their execution
      executed_hooks = []

      # Add a hook with an if condition
      if_hook = proc { executed_hooks << :if_hook }
      task.add_hook(:before_run, { if: proc { condition_var } }, &if_hook)

      # Add a hook with an unless condition
      unless_hook = proc { executed_hooks << :unless_hook }
      task.add_hook(:before_run, { unless: proc { condition_var } }, &unless_hook)

      # Run the hooks with condition_var = false
      task.run_hooks(:before_run, context_obj)

      # Verify that only the unless hook ran
      expect(executed_hooks).to eq([:unless_hook])

      # Reset executed hooks
      executed_hooks.clear

      # Set condition_var to true and run hooks again
      context_obj.condition_var = true
      task.run_hooks(:before_run, context_obj)

      # Verify that only the if hook ran
      expect(executed_hooks).to eq([:if_hook])
    end
  end

  describe 'connection options' do
    it 'processes from connections' do
      task.process_connection_options(:target, { from: :source })

      expect(task.connections[:source]).to include(:target)
    end

    it 'processes to connections' do
      task.process_connection_options(:source, { to: :target })

      expect(task.connections[:source]).to eq([:target])
    end

    it 'processes queue subscriptions' do
      task.process_connection_options(:consumer, { queues: %i[high_priority low_priority] })

      expect(task.queue_subscriptions[:consumer]).to eq(%i[high_priority low_priority])
    end
  end

  describe 'stage options' do
    it 'applies accumulator-specific options' do
      options = {}
      task.add_stage(:accumulator, :test_accumulator, options)
      stage_options = task.pipeline.first[:options]

      expect(stage_options[:batch_size]).to eq(task.config[:batch_size])
      expect(stage_options[:flush_interval]).to be_a(Float)
    end

    it 'applies processor-specific options' do
      options = {}
      task.add_stage(:processor, :test_processor, options)
      stage_options = task.pipeline.first[:options]

      expect(stage_options[:max_threads]).to eq(task.config[:max_threads])
      expect(stage_options[:threads]).to eq(task.config[:max_threads])
      expect(stage_options[:max_retries]).to eq(task.config[:max_retries])
    end

    it 'applies cow_fork-specific options' do
      options = {}
      task.add_stage(:cow_fork, :test_fork, options)
      stage_options = task.pipeline.first[:options]

      expect(stage_options[:fork]).to eq(:cow)
      expect(stage_options[:type]).to eq(:cow)
      expect(stage_options[:max_processes]).to eq(task.config[:max_processes])
      expect(stage_options[:processes]).to eq(task.config[:max_processes])
    end
  end

  describe 'validation' do
    it 'validates placement of stages that require accumulator stages' do
      # Add an accumulator first, then a stage that requires it
      task.add_accumulator(:accumulator)
      task.add_stage(:cow_fork, :consumer)

      # No error should be raised since validation passes
      expect(task.send(:validate_stage_placement, :cow_fork, :consumer)).to be_nil
    end

    it 'warns when a stage should have a prerequisite stage' do
      # Create a temporary class to extend Task for spying
      temp_task = Class.new(described_class) do
        def initialize
          super
          # Initialize pipeline with the test stages
          @pipeline = [
            { type: :processor, name: :source, options: {} },
            { type: :cow_fork, name: :consumer, options: {} }
          ]
          @connections = {}
        end
      end

      # Create an instance with a spy for warn
      task2 = temp_task.new
      allow(task2).to receive(:warn)

      # Call the method directly
      task2.send(:validate_stage_placement, :cow_fork, :consumer)

      # Verify the warning was issued
      expect(task2).to have_received(:warn).with(/COW fork stage consumer should follow an accumulator stage/)
    end
  end

  describe 'running a task' do
    let(:context) { double('context') }

    it 'runs a simple pipeline' do
      # Since we've added a stage to the task, a pipeline will be created instead
      # of a runner, so let's test for that behavior
      pipeline_double = instance_double(Minigun::Pipeline)
      allow(Minigun::Pipeline).to receive(:new).and_return(pipeline_double)
      allow(pipeline_double).to receive_messages(build_pipeline: pipeline_double, run: pipeline_double)
      allow(pipeline_double).to receive(:shutdown)

      # Add a stage to the task
      task.add_stage(:processor, :test)

      # Execute the task's run method and test the pipeline is used
      task.run(context)

      # Verify our pipeline was created and run
      expect(Minigun::Pipeline).to have_received(:new)
      expect(pipeline_double).to have_received(:build_pipeline)
      expect(pipeline_double).to have_received(:run)
      expect(pipeline_double).to have_received(:shutdown)
    end

    it 'runs a custom pipeline' do
      task.pipeline_definition = proc { puts 'defining pipeline' }

      # Create a double for the pipeline
      pipeline_double = instance_double(Minigun::Pipeline)
      allow(Minigun::Pipeline).to receive(:new).with(context, hash_including(custom: true, task: task)).and_return(pipeline_double)
      allow(pipeline_double).to receive_messages(build_pipeline: pipeline_double, run: pipeline_double)
      allow(pipeline_double).to receive(:shutdown)

      # Allow setting instance variables
      allow(pipeline_double).to receive(:instance_variable_set)

      # Run the task
      task.run(context)

      # Verify our expectations
      expect(pipeline_double).to have_received(:build_pipeline)
      expect(pipeline_double).to have_received(:run)
      expect(pipeline_double).to have_received(:shutdown)
    end
  end
end
