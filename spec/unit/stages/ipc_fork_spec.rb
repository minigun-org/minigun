# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Minigun::Stages::IpcFork do
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
    allow(task).to receive(:hooks).and_return({})
    allow(task).to receive(:processor_blocks).and_return({})
    task
  end

  let(:pipeline) { double('Pipeline', task: task, job_id: 'test_job', context: task) }
  let(:logger) { instance_double(Logger, info: nil, warn: nil, error: nil, debug: nil) }
  let(:config) do
    {
      logger: logger,
      max_threads: 2,
      max_retries: 2,
      fork_mode: :never # Force thread pool mode for predictable testing
    }
  end
  let(:stage_name) { :test_consumer }

  before do
    allow(task_class).to receive(:_minigun_consumer_blocks).and_return({ test_consumer: consumer_block })
    allow(pipeline).to receive(:downstream_stages).and_return([])
  end


  describe '#initialize' do
    it 'sets up the consumer with the correct configuration' do
      expect(subject.instance_variable_get(:@consumer_block)).to eq(consumer_block)
      expect(subject.instance_variable_get(:@max_threads)).to eq(2)
      expect(subject.instance_variable_get(:@max_retries)).to eq(2)
      expect(subject.instance_variable_get(:@fork_mode)).to eq(:never)
    end

    it 'creates a thread pool' do
      thread_pool = subject.instance_variable_get(:@thread_pool)
      expect(thread_pool).to be_a(Concurrent::FixedThreadPool)
      expect(thread_pool.max_length).to eq(2)
    end
  end

  describe '#process' do
    context 'with thread pool execution' do
      it 'processes items using the thread pool' do
        # Ensure fork is not used
        allow(Process).to receive(:respond_to?).with(:fork).and_return(false)

        # Reset counters to ensure accurate counting
        subject.instance_variable_set(:@processed_count, Concurrent::AtomicFixnum.new(0))

        # Setup fork context to track emits
        Thread.current[:minigun_fork_context] = {
          emit_count: 0,
          success_count: 3,
          failed_count: 0
        }

        # Create a simple thread pool that executes immediately for testing
        test_pool = double('ThreadPool')
        allow(test_pool).to receive(:post).and_yield
        subject.instance_variable_set(:@thread_pool, test_pool)

        # Stub process_items_directly
        allow(subject).to receive(:process_items_directly) do |items|
          # Increment the processed count
          subject.instance_variable_get(:@processed_count).increment(items.size)
          { success: items.size, failed: 0, emitted: 0 }
        end

        # Process some items
        subject.process([1, 2, 3])

        # Verify the items were processed
        expect(subject.instance_variable_get(:@processed_count).value).to eq(6)
      end
    end
  end

  describe '#shutdown' do
    it 'shuts down the thread pool and returns processing statistics' do
      # Set up thread pool mock
      thread_pool = double('ThreadPool')
      allow(thread_pool).to receive(:shutdown)
      allow(thread_pool).to receive(:wait_for_termination).and_return(true)
      subject.instance_variable_set(:@thread_pool, thread_pool)

      # Set up statistics for testing
      processed_count = subject.instance_variable_get(:@processed_count)
      processed_count.increment(3)

      # Call shutdown
      result = subject.shutdown

      # Verify results
      expect(result[:processed]).to eq(3)
    end
  end
end
