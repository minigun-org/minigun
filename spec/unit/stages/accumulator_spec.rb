# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Minigun::Stages::Accumulator do
  subject { described_class.new(stage_name, pipeline, config) }

  let(:task) do
    task = Minigun::Task.new
    task.instance_variable_set(:@accumulator_blocks, { test_accumulator: proc {} })
    task
  end

  let(:context) { double('Context') }
  let(:pipeline) { double('Pipeline', task: task, job_id: 'test_job', send_to_next_stage: nil, context: context, downstream_stages: []) }
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
    it 'starts the flush timer via hooks' do
      timer = Concurrent::TimerTask.new(execution_interval: 0.1) {}
      allow(Concurrent::TimerTask).to receive(:new).and_return(timer)
      expect(timer).to receive(:execute)

      # The run method will call the before_start hooks
      subject.run
    end
  end

  describe '#process' do
    it 'accumulates items by their type' do
      # Disable the flush batch to focus on just the accumulation
      allow(subject).to receive(:flush_batch_if_needed)

      subject.process('item1')
      subject.process('item2')

      batches = subject.instance_variable_get(:@batches)
      expect(batches['String']).to eq(%w[item1 item2])
      expect(subject.instance_variable_get(:@accumulated_count).value).to eq(2)
    end

    it 'flushes when a batch reaches max batch size' do
      # Test flush_batch_if_needed directly instead of through process
      batch = %w[item1 item2 item3 item4 item5]
      subject.instance_variable_set(:@batches, { 'String' => batch })

      expect(subject).to receive(:flush_batch_items).with('String', batch)

      # Call the method directly
      subject.send(:flush_batch_if_needed, 'String')
    end
  end

  describe '#shutdown' do
    it 'shuts down the timer and flushes all batches via hooks' do
      timer = Concurrent::TimerTask.new(execution_interval: 0.1) {}
      subject.instance_variable_set(:@flush_timer, timer)

      expect(timer).to receive(:shutdown)
      expect(subject).to receive(:flush_all_batches)

      # Add some items to the batches directly
      subject.instance_variable_set(:@batches, { 'String' => %w[item1 item2] })
      subject.instance_variable_set(:@accumulated_count, Concurrent::AtomicFixnum.new(2))

      # In the updated design, the Base class's shutdown calls after_finish hooks
      # which will handle flushing and timer shutdown
      result = subject.shutdown
      expect(result[:accumulated]).to eq(2)
    end
  end

  describe '#flush_all_batches' do
    it 'flushes all non-empty batches' do
      # Set up batches with different item types
      subject.instance_variable_set(:@batches, {
                                      'String' => ['string_item'],
                                      'Integer' => [123],
                                      'Array' => [[1, 2, 3]]
                                    })

      # We expect flush_batch_items to be called for each batch
      expect(subject).to receive(:flush_batch_items).with('String', ['string_item'])
      expect(subject).to receive(:flush_batch_items).with('Integer', [123])
      expect(subject).to receive(:flush_batch_items).with('Array', [[1, 2, 3]])

      # Make the private method accessible for testing
      subject.send(:flush_all_batches)
    end
  end

  describe '#flush_batch' do
    it 'emits batches of items according to batch_size' do
      # Create a test array
      items = Array.new(5) { |i| "item#{i}" }

      # Should emit in batches of 2 (as per config)
      expect(subject).to receive(:emit).with(%w[item0 item1], :String).exactly(1).time
      expect(subject).to receive(:emit).with(%w[item2 item3], :String).exactly(1).time
      expect(subject).to receive(:emit).with(['item4'], :String).exactly(1).time

      # Make the private method accessible for testing
      subject.send(:flush_batch_items, 'String', items)
    end
  end

  describe 'hooks' do
    it 'has before_start hook that starts the flush timer' do
      expect(described_class.before_start_hooks.size).to be >= 1

      # Add a custom hook to verify it gets called
      hook_called = false
      subject.before_start { hook_called = true }

      subject.run
      expect(hook_called).to be true
    end

    it 'has after_finish hook that flushes batches' do
      expect(described_class.after_finish_hooks.size).to be >= 1

      # Add a custom hook to verify it gets called
      hook_called = false
      subject.after_finish { hook_called = true }

      subject.shutdown
      expect(hook_called).to be true
    end
  end
end
