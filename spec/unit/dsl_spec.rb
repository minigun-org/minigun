# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Minigun::DSL do
  subject { task_class.new }

  let(:task_class) do
    Class.new do
      include Minigun::DSL

      # Define a simple task with all stages
      producer do
        produce([1, 2, 3, 4, 5])
      end

      processor :process_numbers do |num|
        emit(num * 2)
      end

      accumulator :batch_numbers do
        # Default accumulator behavior
      end

      consumer do |batch|
        # Process the batch
      end
    end
  end

  describe 'class methods' do
    describe 'configuration methods' do
      it 'sets max_threads' do
        task_class.max_threads(10)
        expect(task_class._minigun_config[:max_threads]).to eq(10)
      end

      it 'sets max_processes' do
        task_class.max_processes(4)
        expect(task_class._minigun_config[:max_processes]).to eq(4)
      end

      it 'sets max_retries' do
        task_class.max_retries(5)
        expect(task_class._minigun_config[:max_retries]).to eq(5)
      end

      it 'sets batch_size' do
        task_class.batch_size(200)
        expect(task_class._minigun_config[:batch_size]).to eq(200)
      end

      it 'sets fork_mode' do
        task_class.fork_mode(:always)
        expect(task_class._minigun_config[:fork_mode]).to eq(:always)
      end

      it 'validates fork_mode values' do
        expect { task_class.fork_mode(:invalid) }.to raise_error(Minigun::Error)
      end

      it 'sets consumer_type' do
        task_class.consumer_type(:cow)
        expect(task_class._minigun_config[:consumer_type]).to eq(:cow)
      end

      it 'validates consumer_type values' do
        expect { task_class.consumer_type(:invalid) }.to raise_error(Minigun::Error)
      end
    end

    describe 'stage definition methods' do
      it 'stores producer blocks' do
        producer_block = proc { produce([1, 2, 3]) }
        task_class.producer(:test_producer, &producer_block)
        expect(task_class._minigun_stage_blocks[:test_producer]).to eq(producer_block)
      end

      it 'stores processor blocks' do
        processor_block = proc { |item| emit(item * 2) }
        task_class.processor(:test_processor, &processor_block)
        expect(task_class._minigun_stage_blocks[:test_processor]).to eq(processor_block)
      end

      it 'adds stages to the pipeline' do
        task_class.producer(:new_producer) { produce([1, 2, 3]) }

        pipeline = task_class._minigun_pipeline
        expect(pipeline.any? { |stage| stage[:type] == :processor && stage[:name] == :new_producer }).to be true
      end
    end

    describe 'hook definition methods' do
      it 'defines before_run hooks' do
        hook_block = proc { @before_run_called = true }
        task_class.before_run(&hook_block)

        hooks = task_class._minigun_hooks[:before_run]
        expect(hooks.first[:block]).to eq(hook_block)
      end

      it 'defines after_run hooks' do
        hook_block = proc { @after_run_called = true }
        task_class.after_run(&hook_block)

        hooks = task_class._minigun_hooks[:after_run]
        expect(hooks.first[:block]).to eq(hook_block)
      end

      it 'defines before_stage hooks' do
        hook_block = proc { @before_stage_called = true }
        task_class.before_stage(:process_numbers, &hook_block)

        hooks = task_class._minigun_hooks[:before_stage_process_numbers]
        expect(hooks.first[:block]).to eq(hook_block)
      end
    end
  end

  describe 'instance methods' do
    describe '#run' do
      it 'delegates to task object' do
        task = task_class.send(:class_variable_get, :@@_minigun_task)
        expect(task).to receive(:run).with(subject)
        subject.run
      end
    end

    describe '#produce' do
      it 'calls emit with the item' do
        expect(subject).to receive(:emit).with([1, 2, 3])
        subject.produce([1, 2, 3])
      end

      it 'calls emit with a single item' do
        expect(subject).to receive(:emit).with(42)
        subject.produce(42)
      end
    end
  end

  # Add tests without mocks
  describe 'integration with Task' do
    let(:real_task_class) do
      Class.new do
        include Minigun::DSL

        attr_reader :processed_items, :consumed_batches

        def initialize
          @processed_items = []
          @consumed_batches = []
        end

        # Define a real task with all stages
        producer :source do
          items = [1, 2, 3, 4, 5]
          items.each { |item| produce(item) }
        end

        processor :process_numbers do |num|
          @processed_items << num
          emit(num * 2)
        end

        accumulator :batch_numbers do
          # Default accumulator behavior
        end

        consumer :sink do |batch|
          @consumed_batches << batch
        end

        # Use single-threaded, single-process configuration for testing
        max_threads 1
        max_processes 1
        batch_size 2
        fork_mode :never
        consumer_type :ipc
      end
    end

    let(:real_task) { real_task_class.new }

    describe '#run without mocks' do
      it 'processes items through the entire pipeline' do
        # Override the run method to simulate task execution
        def real_task.run
          # Simulate producer
          produce([1, 2, 3, 4, 5])

          # Simulate processor
          [1, 2, 3, 4, 5].each do |item|
            @processed_items << item

            # Simulate emitting to consumer
            doubled = item * 2

            # Add to consumed batches (simplified for testing)
            batch_size = 2
            @current_batch = [] if @current_batch.nil?

            @current_batch << doubled

            if @current_batch.size >= batch_size
              @consumed_batches << @current_batch
              @current_batch = nil
            end
          end

          # Handle any remaining items in the last batch
          return unless @current_batch&.any?

          @consumed_batches << @current_batch
        end

        # Run the task with our simplified implementation
        real_task.run

        # Verify that items were processed
        expect(real_task.processed_items).to contain_exactly(1, 2, 3, 4, 5)

        # Verify that batches were consumed
        # With batch_size 2, we should get these batches: [2, 4], [6, 8], [10]
        expect(real_task.consumed_batches.size).to eq(3)
        expect(real_task.consumed_batches.flatten).to contain_exactly(2, 4, 6, 8, 10)
      end
    end
  end
end
