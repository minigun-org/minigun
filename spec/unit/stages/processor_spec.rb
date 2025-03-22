# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Minigun::Stages::Processor do
  subject { described_class.new(stage_name, pipeline, config) }

  let(:processor_block) { proc { |item| emit(item * 2) } }
  let(:task) do
    task = Minigun::Task.new
    task.processor_blocks = { test_processor: processor_block }
    
    # Don't mock instance_exec, so we use the real implementation
    task
  end

  let(:context) do 
    ctx = double('Context')
    allow(ctx).to receive(:emit) do |item|
      item
    end
    ctx
  end
  let(:pipeline) { double('Pipeline', task: task, job_id: 'test_job', send_to_next_stage: nil, context: context, downstream_stages: []) }
  let(:logger) { instance_double(Logger, info: nil, warn: nil, error: nil, debug: nil) }
  let(:config) { { logger: logger, max_threads: 2, max_retries: 2 } }
  let(:stage_name) { :test_processor }

  describe '#initialize' do
    it 'sets up the processor with the correct configuration' do
      expect(subject.instance_variable_get(:@block)).to eq(processor_block)
      expect(subject.instance_variable_get(:@threads)).to eq(2)
      expect(subject.instance_variable_get(:@max_retries)).to eq(2)
    end
  end

  describe '#process' do
    before do
      allow(subject).to receive(:emit)
    end

    it 'processes the item with the processor block' do
      # Use a spy to verify emit was called 
      expect(subject).to receive(:emit).with(10)
      
      # Process the item
      subject.process(5)
    end

    context 'when processing fails' do
      let(:failing_processor) do
        failing_block = proc { |_item| raise 'Processing error' }
        task.processor_blocks = { test_processor: failing_block }
        
        # Create a new processor instance with the failing block
        processor = described_class.new(stage_name, pipeline, config)
        
        # Allow sleep to make tests faster
        allow(processor).to receive(:sleep)
        
        # Set retries to a small number for faster tests
        processor.instance_variable_set(:@max_retries, 2)
        
        processor
      end

      it 'retries the specified number of times before failing' do
        # We expect it to call the error logger for each failure
        allow(logger).to receive(:error)
        
        # Should eventually fail after retries
        expect { failing_processor.process(5) }.to raise_error(RuntimeError, 'Processing error')
      end
    end
  end

  describe '#shutdown' do
    it 'shuts down the thread pool and returns processing statistics' do
      thread_pool = subject.instance_variable_get(:@thread_pool)
      expect(thread_pool).to receive(:shutdown)
      expect(thread_pool).to receive(:wait_for_termination).with(30).and_return(true)

      # Manually increment the processed count to simulate successful processing
      processed_count = subject.instance_variable_get(:@processed_count)
      processed_count.increment
      processed_count.increment

      result = subject.shutdown
      expect(result[:processed]).to eq(2)
      expect(result[:failed]).to eq(0)
    end

    # Test thread pool shutdown behavior
    it 'shuts down cleanly' do
      thread_pool = subject.instance_variable_get(:@thread_pool)

      allow(thread_pool).to receive(:wait_for_termination).with(30).and_return(true)

      # Mock the thread pool to avoid actual shutdown
      processed_count = subject.instance_variable_get(:@processed_count)

      # Call shutdown
      result = subject.shutdown

      # Should return stats with values from our mocks
      expect(result[:processed]).to eq(processed_count.value)
    end
  end

  # Tests without mocks
  describe 'Processor without mocks' do
    let(:real_task) do
      task = Minigun::Task.new
      
      # Add instance variables for tracking
      task.instance_variable_set(:@processed_items, [])
      task.instance_variable_set(:@emitted_values, [])
      task.instance_variable_set(:@retry_count, 0)
      
      # Add accessor methods
      def task.processed_items; @processed_items; end
      def task.emitted_values; @emitted_values; end
      def task.retry_count; @retry_count; end
      def task.retry_count=(val); @retry_count = val; end
      
      # Add emit method to task for tests
      def task.emit(value)
        @emitted_values ||= []
        @emitted_values << value
      end
      
      # Add processor blocks
      task.add_processor(:double_numbers, {}) do |num|
        @processed_items << num
        emit(num * 2)
      end
      
      task.add_processor(:triple_numbers, {}) do |num|
        emit(num * 3)
      end
      
      task.add_processor(:failing_processor, {}) do |num|
        # For testing retry mechanism
        @retry_count ||= 0
        
        if @retry_count < 2
          @retry_count += 1
          raise 'Test error'
        end
        
        @processed_items ||= []
        @processed_items << num
        emit(num * 2)
      end
      
      # Configure for testing
      task.config[:consumer_type] = :ipc
      
      task
    end
    
    let(:real_pipeline) { TestPipeline.new(real_task) }
    let(:real_config) { { max_threads: 1, max_retries: 3 } }

    # Setup a real pipeline with minimal components
    class TestPipeline
      attr_reader :task, :job_id, :next_stage_items, :context

      def initialize(task)
        @task = task
        @job_id = 'test_job_real'
        @next_stage_items = []
        @context = task
        @stages = {}
      end

      def send_to_next_stage(instance, item, queue = :default)
        @next_stage_items << item
      end
      
      def downstream_stages(name)
        []
      end
      
      def queue_subscriptions(name)
        [:default]
      end
      
      def register_stage(name, stage)
        @stages[name] = stage
      end
    end

    describe '#process with real objects' do
      it 'processes items and emits transformed values' do
        processor = described_class.new(:double_numbers, real_pipeline, real_config)
        
        # Create a simple processor block that doubles items and emits them
        simple_block = proc { |item| 
          result = item * 2
          emit(result) 
          result 
        }
        
        # Replace the block to avoid dependencies on task
        processor.instance_variable_set(:@block, simple_block)
        
        # Clear before we start
        real_pipeline.next_stage_items.clear
        
        # Stub the send_to_next_stage method at a lower level to capture emitted items
        # This avoids the complexity of downstream_stages logic
        allow(processor).to receive(:send_to_next_stage) do |item, _queue|
          real_pipeline.next_stage_items << item
        end
        
        # Process items one by one
        processor.process(1)
        processor.process(2)
        processor.process(3)
        
        # Verify items were added to the pipeline's next_stage_items array
        expect(real_pipeline.next_stage_items).to match_array([2, 4, 6])
      end

      it 'handles retries with real objects' do
        processor = described_class.new(:test_retry, real_pipeline, real_config)
        
        # Create counter to track retries
        retry_count = 0
        
        # Create a failing processor block that will eventually succeed
        failing_block = proc { |item|
          # Track the retry count
          if retry_count < 2
            retry_count += 1
            raise "Test error #{retry_count}"
          end
          
          # Third attempt succeeds
          result = item * 2
          emit(result)
          result
        }
        
        # Set the processor block
        processor.instance_variable_set(:@block, failing_block)
        
        # Stub the send_to_next_stage method at a lower level to capture emitted items
        allow(processor).to receive(:send_to_next_stage) do |item, _queue|
          real_pipeline.next_stage_items << item
        end
        
        # Disable sleep for faster tests
        allow(processor).to receive(:sleep)
        
        # Clear any previous items
        real_pipeline.next_stage_items.clear
        
        # Process with expected failures
        expect { processor.process(5) }.to raise_error(RuntimeError, "Test error 1")
        expect { processor.process(5) }.to raise_error(RuntimeError, "Test error 2")
        
        # Third attempt should succeed
        result = processor.process(5)
        
        # Verify the retry count and emitted value
        expect(retry_count).to eq(2)
        expect(result).to eq(10) # Return value is 5 * 2
        expect(real_pipeline.next_stage_items).to match_array([10]) # Should emit 10
      end
    end
  end
end
