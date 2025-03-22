# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Minigun::Stages::Accumulator do
  subject { described_class.new(stage_name, pipeline, config) }

  let(:task_class) do
    Class.new do
      def self._minigun_accumulator_blocks
        {}
      end
    end
  end

  let(:task) do
    task = double('Task')
    allow(task).to receive_messages(class: task_class, _minigun_hooks: {})
    task
  end

  let(:pipeline) { double('Pipeline', task: task, job_id: 'test_job', send_to_next_stage: nil) }
  let(:logger) { instance_double(Logger, info: nil, warn: nil, error: nil, debug: nil) }
  let(:config) do
    {
      logger: logger,
      batch_size: 2,
      flush_interval: 0.1,
      max_batch_size: 5
    }
  end
  let(:stage_name) { :test_accumulator }


  describe '#initialize' do
    it 'sets up the accumulator with the correct configuration' do
      expect(subject.instance_variable_get(:@batch_size)).to eq(2)
      expect(subject.instance_variable_get(:@flush_interval)).to eq(0.1)
      expect(subject.instance_variable_get(:@max_batch_size)).to eq(5)
    end
  end

  describe '#run' do
    it 'starts the flush timer' do
      flush_timer = subject.instance_variable_get(:@flush_timer)
      expect(flush_timer).to receive(:execute)
      expect(subject).to receive(:on_start)

      subject.run
    end
  end

  describe '#process' do
    it 'accumulates items by their type' do
      allow(subject).to receive(:determine_batch_key).and_return('String')

      subject.process('item1')
      subject.process('item2')

      batches = subject.instance_variable_get(:@batches)
      expect(batches['String'].size).to eq(2)
      expect(subject.instance_variable_get(:@accumulated_count)).to eq(2)
    end

    it 'flushes when a batch reaches max batch size' do
      allow(subject).to receive(:determine_batch_key).and_return('String')
      expect(subject).to receive(:flush_batch_items).with('String', anything)

      # Add items up to max_batch_size
      5.times { |i| subject.process("item#{i}") }

      batches = subject.instance_variable_get(:@batches)
      expect(batches['String'].size).to eq(0) # Should be empty after flush
    end
  end

  describe '#shutdown' do
    it 'shuts down the timer and flushes all batches' do
      flush_timer = subject.instance_variable_get(:@flush_timer)

      expect(flush_timer).to receive(:shutdown)
      expect(subject).to receive(:flush_all_batches)
      expect(subject).to receive(:on_finish)

      # Add some items to accumulate
      allow(subject).to receive(:determine_batch_key).and_return('String')
      subject.process('item1')
      subject.process('item2')

      result = subject.shutdown
      expect(result[:accumulated]).to eq(2)
    end
  end

  describe '#flush_all_batches' do
    it 'flushes all non-empty batches' do
      # Add items of different types
      allow(subject).to receive(:determine_batch_key).and_return('String', 'Integer', 'Array')
      subject.process('string_item')
      subject.process(123)
      subject.process([1, 2, 3])

      # Make the private method accessible for testing
      accumulator_class = Class.new(Minigun::Stages::Accumulator) do
        def flush_all_batches_test
          flush_all_batches
        end

        # Make flush_batch_items public for testing
        public :flush_batch_items
      end

      test_subject = accumulator_class.new(stage_name, pipeline, config)
      allow(test_subject).to receive(:determine_batch_key).and_return('String', 'Integer', 'Array')
      test_subject.process('string_item')
      test_subject.process(123)
      test_subject.process([1, 2, 3])

      # Expect flush_batch_items instead of flush_batch
      expect(test_subject).to receive(:flush_batch_items).with('String', ['string_item'])
      expect(test_subject).to receive(:flush_batch_items).with('Integer', [123])
      expect(test_subject).to receive(:flush_batch_items).with('Array', [[1, 2, 3]])

      test_subject.flush_all_batches_test
    end
  end

  describe '#flush_batch' do
    it 'emits batches of items according to batch_size' do
      # Make the private method accessible for testing
      accumulator_class = Class.new(Minigun::Stages::Accumulator) do
        # Make flush_batch_items directly testable
        public :flush_batch_items
      end

      test_subject = accumulator_class.new(stage_name, pipeline, config)

      # Create a test array
      items = Array.new(5) { |i| "item#{i}" }

      # Should emit in batches of 2 (as per config)
      expect(test_subject).to receive(:emit).with(%w[item0 item1])
      expect(test_subject).to receive(:emit).with(%w[item2 item3])
      expect(test_subject).to receive(:emit).with(['item4'])

      test_subject.flush_batch_items('String', items)
    end
  end
end
