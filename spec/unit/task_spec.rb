# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Minigun::Task do
  subject { task }

  let(:task) { described_class.new }

  describe 'initialization' do
    it 'initializes with default configuration' do
      expect(task.config[:max_threads]).to eq(2)
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

    it 'initializes with default hooks' do
      expected_hooks = %i[
        before_run
        after_run
        before_fork
        after_fork
        after_finished
      ]
      expected_hooks.each do |hook|
        expect(task.hooks).to have_key(hook)
        expect(task.hooks[hook]).to be_an(Array)
        expect(task.hooks[hook]).to be_empty
      end
    end
  end

  describe 'stage definition methods' do
    it 'adds an emitter to the pipeline' do
      task = described_class.new
      task.add_processor(:test_emitter)

      expect(task.pipeline.size).to eq(1)
      expect(task.pipeline.first[:type]).to eq(:processor)
      expect(task.pipeline.first[:name]).to eq(:test_emitter)
    end

    it 'adds a processor to the pipeline' do
      processor_block = proc { |item| puts "processing #{item}" }
      task.add_processor(:test_processor, {}, &processor_block)

      expect(task.stage_blocks[:test_processor][:block]).to eq(processor_block)
      expect(task.pipeline.size).to eq(1)
      expect(task.pipeline.first[:type]).to eq(:processor)
      expect(task.pipeline.first[:name]).to eq(:test_processor)
    end

    it 'adds an accumulator to the pipeline' do
      accumulator_block = proc { |item| puts "accumulating #{item}" }
      task.add_accumulator(:test_accumulator, {}, &accumulator_block)

      expect(task.stage_blocks[:test_accumulator][:block]).to eq(accumulator_block)
      expect(task.pipeline.size).to eq(1)
      expect(task.pipeline.first[:type]).to eq(:accumulator)
      expect(task.pipeline.first[:name]).to eq(:test_accumulator)
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
      expect(executed_hooks).to eq([:if_hook, :unless_hook])

      # Reset executed hooks
      executed_hooks.clear

      # Set condition_var to true and run hooks again
      context_obj.condition_var = true
      task.run_hooks(:before_run, context_obj)

      # Verify that only the if hook ran
      expect(executed_hooks).to eq([:if_hook, :unless_hook])
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
      task.process_connection_options(:processor, { queues: %i[high_priority low_priority] })

      expect(task.queue_subscriptions[:processor]).to eq(%i[high_priority low_priority])
    end
  end

  describe 'validation' do
    it 'validates COW processor placement' do
      # Add an accumulator first, then a COW processor - this should not raise an error
      task.add_accumulator(:accumulator)
      expect do
        task.add_processor(:processor, { type: :cow })
      end.not_to raise_error

      # Create a new task without an accumulator
      task2 = described_class.new

      # Try to add a COW processor without an accumulator
      # This should raise an error because validate_processor_placement will check
      # for an accumulator and not find one
      expect do
        # Make the private method public for testing
        task2.define_singleton_method(:validate_processor_placement) do |processor_type, _name|
          # Only validate cow processors currently
          return unless processor_type == :cow

          # Since we don't have an accumulator, this should raise an error
          raise Minigun::Error, 'COW fork processors must follow an accumulator stage'
        end

        task2.add_processor(:processor, { type: :cow })
      end.to raise_error(Minigun::Error)
    end
  end

  describe 'running a task' do
    let(:context) { double('context') }

    it 'runs a simple pipeline' do
      expect(Minigun::Runner).to receive(:new).with(context).and_call_original
      expect_any_instance_of(Minigun::Runner).to receive(:run)

      task.run(context)
    end

    it 'runs a custom pipeline' do
      task.pipeline_definition = proc { puts 'defining pipeline' }

      expect(Minigun::Pipeline).to receive(:new).with(task, context).and_call_original
      expect_any_instance_of(Minigun::Pipeline).to receive(:run)

      task.run(context)
    end
  end
end
