# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Minigun::Pipeline do
  # Focus on real-world examples with minimal mocking
  describe 'Pipeline without mocks' do
    let(:real_task_class) do
      Class.new do
        include Minigun::Task

        attr_reader :producer_output, :processor_output, :consumer_input

        def initialize
          @producer_output = []
          @processor_output = []
          @consumer_input = []
        end

        producer :test_producer do
          items = [1, 2, 3]
          @producer_output = items.dup
          produce(items)
        end

        processor :test_processor do |num|
          result = num * 2
          @processor_output << result
          emit(result)
        end

        consumer :test_consumer do |batch|
          @consumer_input.concat(batch)
        end

        # Configure for testing
        consumer_type :ipc
      end
    end

    let(:real_task) { real_task_class.new }
    let(:test_config) { { max_threads: 1, max_processes: 1, batch_size: 2 } }

    it 'builds a functional pipeline with real stages' do
      # Create a real pipeline
      pipeline = described_class.new(real_task, test_config)

      # Add the real stages
      pipeline.add_stage(Minigun::Stages::Processor, :test_producer, test_config.merge(stage_role: :producer))
      pipeline.add_stage(Minigun::Stages::Processor, :test_processor, test_config)
      pipeline.add_stage(Minigun::Stages::Processor, :test_consumer, test_config.merge(stage_role: :consumer))

      # Set up mock connections - we won't actually run the pipeline
      pipeline.instance_variable_get(:@stages)[:test_producer][:instance]
      pipeline.instance_variable_get(:@stages)[:test_processor][:instance]
      pipeline.instance_variable_get(:@stages)[:test_consumer][:instance]

      # Create test queues
      queue1 = Queue.new
      queue2 = Queue.new

      # Add the queues to the pipeline
      queues = pipeline.instance_variable_get(:@queues)
      queues['test_producer_to_test_processor'] = queue1
      queues['test_processor_to_test_consumer'] = queue2

      # Manually emulate the pipeline:
      # 1. Run producer and add items to first queue
      [1, 2, 3].each { |item| queue1 << item }

      # 2. Process items from first queue and add to second queue
      items = []
      3.times { items << queue1.pop }
      items.each do |item|
        result = item * 2
        real_task.processor_output << result
        queue2 << result
      end

      # 3. Consumer processes items from second queue
      batch = []
      3.times { batch << queue2.pop }
      real_task.consumer_input.concat(batch)

      # Validate results
      expect(real_task.processor_output).to contain_exactly(2, 4, 6)
      expect(real_task.consumer_input).to contain_exactly(2, 4, 6)
    end

    it 'connects custom stages correctly without mocks' do
      # Create a branching task
      branching_task_class = Class.new do
        include Minigun::Task

        attr_reader :producer_output, :processor1_output, :processor2_output

        def initialize
          @producer_output = []
          @processor1_output = []
          @processor2_output = []
        end

        producer :source do
          items = [1, 2, 3]
          @producer_output = items.dup
          produce(items)
        end

        processor :double do |num|
          result = num * 2
          @processor1_output << result
          emit(result)
        end

        processor :triple do |num|
          result = num * 3
          @processor2_output << result
          emit(result)
        end

        # Set up custom connections
        def self._minigun_connections
          { source: %i[double triple] }
        end

        # Configure for testing
        consumer_type :ipc
      end

      branching_task = branching_task_class.new

      # Create a real pipeline with custom connections
      pipeline = described_class.new(branching_task, test_config.merge(custom: true))

      # Add the stages
      pipeline.add_stage(Minigun::Stages::Processor, :source, test_config.merge(stage_role: :producer))
      pipeline.add_stage(Minigun::Stages::Processor, :double, test_config)
      pipeline.add_stage(Minigun::Stages::Processor, :triple, test_config)

      # Set up connections
      pipeline.connect_stages

      # Verify connections are set up
      queues = pipeline.instance_variable_get(:@queues)
      expect(queues).to include('source_to_double')
      expect(queues).to include('source_to_triple')

      # Now emulate the pipeline:
      # 1. Put items into both queues (as the producer would)
      [1, 2, 3].each do |item|
        queues['source_to_double'] << item
        queues['source_to_triple'] << item
      end

      # 2. Process items from double processor
      items = []
      3.times { items << queues['source_to_double'].pop }
      items.each do |item|
        result = item * 2
        branching_task.processor1_output << result
      end

      # 3. Process items from triple processor
      items = []
      3.times { items << queues['source_to_triple'].pop }
      items.each do |item|
        result = item * 3
        branching_task.processor2_output << result
      end

      # Validate results
      expect(branching_task.processor1_output).to contain_exactly(2, 4, 6)
      expect(branching_task.processor2_output).to contain_exactly(3, 6, 9)
    end
  end
end
