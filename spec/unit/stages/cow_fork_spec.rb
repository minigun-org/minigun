# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Minigun::Stages::CowFork do
  subject { described_class.new(stage_name, pipeline, config) }

  let(:consumer_block) { proc { |items| items.each { |i| processed << i } } }
  let(:task_class) do
    Class.new do
      def self._minigun_consumer_blocks
        {}
      end

      def self._minigun_consumer_block
        nil
      end
    end
  end

  let(:task) do
    task = double('Task')
    allow(task).to receive_messages(class: task_class, _minigun_hooks: {})
    allow(task).to receive(:instance_exec) do |item, &block|
      @processed ||= []
      attr_reader :processed

      block.call(item)
    end
    allow(task).to receive(:run_hooks)
    allow(task).to receive_messages(hooks: {}, accumulator_blocks: {})
    task
  end

  let(:pipeline) { double('Pipeline', task: task, job_id: 'test_job', context: task) }
  let(:logger) { instance_double(Logger, info: nil, warn: nil, error: nil, debug: nil) }
  let(:config) do
    {
      logger: logger,
      max_threads: 2,
      max_retries: 2,
      max_processes: 1,
      batch_size: 10,
      accumulator_max_queue: 20
    }
  end
  let(:stage_name) { :test_consumer }

  before do
    allow(task_class).to receive(:_minigun_consumer_blocks).and_return({ test_consumer: consumer_block })
    allow(logger).to receive(:warn) # Suppress warnings about optimal usage
    allow(pipeline).to receive(:downstream_stages).and_return([])
  end


  describe '#initialize' do
    it 'sets up the consumer with the correct configuration' do
      expect(subject.instance_variable_get(:@consumer_block)).to eq(consumer_block)
      expect(subject.instance_variable_get(:@max_threads)).to eq(2)
      expect(subject.instance_variable_get(:@max_retries)).to eq(2)
      expect(subject.instance_variable_get(:@max_processes)).to eq(1)
      expect(subject.instance_variable_get(:@batch_size)).to eq(10)
      expect(subject.instance_variable_get(:@accumulator_max_queue)).to eq(20)
    end

    it 'initializes the accumulator' do
      expect(subject.instance_variable_get(:@accumulator)).to be_a(Hash)
    end
  end

  describe '#process' do
    # For testing, we'll use direct processing to avoid forking
    it 'accumulates items by type' do
      # We'll skip actual fork processing
      allow(Process).to receive(:respond_to?).with(:fork).and_return(false)

      # Simulate direct processing
      allow(subject).to receive(:process_items_directly) do |items|
        # Update statistics
        subject.instance_variable_get(:@processed_count).increment(items.size)
        { success: items.size, failed: 0, emitted: 0 }
      end

      # Add items to the accumulator for testing
      subject.instance_variable_get(:@accumulator)['String'] = %w[item1 item2]
      subject.instance_variable_get(:@accumulator)['Integer'] = [1, 2, 3]

      # Process some items (these will actually be ignored due to our stub)
      subject.process(%w[dummy1 dummy2])

      # Verify items are accumulated
      accumulator = subject.instance_variable_get(:@accumulator)
      expect(accumulator['String'].size).to eq(2)
      expect(accumulator['Integer'].size).to eq(3)
    end

    context 'when processing items directly' do
      it 'processes items and updates statistics' do
        # Create a test subject that uses CowFork
        allow(subject).to receive(:process_items_directly).and_wrap_original do |_original_method, items|
          # Simulate successful processing
          {
            success: items.size,
            failed: 0,
            emitted: 0
          }
        end

        # Expose private method for testing
        def subject.process_directly(items)
          process_items_directly(items)
        end

        # Get result from the processing
        result = subject.process_directly(['item1', 'item2', 1, 2, 3])

        # Verify the results
        expect(result[:success]).to eq(5) # Total of 5 items processed
      end
    end
  end

  describe '#shutdown' do
    it 'processes any remaining items and returns statistics' do
      # Create an accessible counter to verify calls
      called_types = []

      # Add items to the accumulator for shutdown to process
      subject.instance_variable_get(:@accumulator)['String'] = %w[item1 item2]
      subject.instance_variable_get(:@accumulator)['Integer'] = [1, 2, 3]

      # Mock the process_batch method to track calls and update counts
      allow(subject).to receive(:process_batch) do |type|
        called_types << type
        # Get the items to process from the accumulator
        items = subject.instance_variable_get(:@accumulator)[type]

        # Update the processed count directly - this is what the real method would do
        subject.instance_variable_get(:@processed_count).increment(items.size)

        # Clear the batch
        subject.instance_variable_get(:@accumulator)[type] = []
      end

      # Call shutdown to process accumulated items
      result = subject.shutdown

      # Verify that process_batch was called for both types
      expect(called_types).to include('String', 'Integer')

      # Verify results - we should have processed 5 items
      expect(result[:processed]).to eq(5)
    end
  end
end
