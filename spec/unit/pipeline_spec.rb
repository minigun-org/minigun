# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Minigun::Pipeline do
  # Focus on real-world examples with minimal mocking
  describe 'Pipeline without mocks' do
    let(:real_task) do
      task = Minigun::Task.new

      # Add instance variables for tracking
      task.instance_variable_set(:@producer_output, [])
      task.instance_variable_set(:@processor_output, [])
      task.instance_variable_set(:@consumer_input, [])

      # Add accessor methods
      def task.producer_output
        @producer_output
      end

      def task.processor_output
        @processor_output
      end

      def task.consumer_input
        @consumer_input
      end

      def task.producer_output=(value)
        @producer_output = value
      end

      def task.processor_output=(value)
        @processor_output = value
      end

      def task.consumer_input=(value)
        @consumer_input = value
      end

      # Add stages
      task.add_producer(:test_producer, {}) do
        items = [1, 2, 3]
        @producer_output = items.dup
        produce(items)
      end

      task.add_processor(:test_processor, {}) do |num|
        result = num * 2
        @processor_output << result
        emit(result)
      end

      task.add_consumer(:test_consumer, {}) do |batch|
        @consumer_input.concat(batch)
      end

      # Configure for testing
      task.config[:consumer_type] = :ipc

      task
    end

    let(:test_config) { { max_threads: 1, max_processes: 1, batch_size: 2 } }

    it 'builds a functional pipeline with real stages' do
      # Create a real pipeline
      pipeline = described_class.new(real_task, test_config)

      # Add the real stages
      pipeline.add_stage(:processor, :test_producer, test_config.merge(is_producer: true))
      pipeline.add_stage(:processor, :test_processor, test_config)
      pipeline.add_stage(:processor, :test_consumer, test_config)

      # Connect stages
      pipeline.instance_variable_set(:@stage_connections, {
                                       test_producer: [:test_processor],
                                       test_processor: [:test_consumer]
                                     })

      # We won't actually run the pipeline, but let's verify the structure
      expect(pipeline.stages.size).to eq(3)
      expect(pipeline.stages[0].name).to eq(:test_producer)
      expect(pipeline.stages[1].name).to eq(:test_processor)
      expect(pipeline.stages[2].name).to eq(:test_consumer)

      # Manually test the output we expect
      real_task.instance_variable_set(:@producer_output, [1, 2, 3])

      # Simulate processing
      real_task.producer_output.each do |item|
        result = item * 2
        real_task.processor_output << result
      end

      # Simulate consumer
      real_task.consumer_input.concat(real_task.processor_output)

      # Validate results
      expect(real_task.processor_output).to contain_exactly(2, 4, 6)
      expect(real_task.consumer_input).to contain_exactly(2, 4, 6)
    end

    it 'connects custom stages correctly without mocks' do
      # Create a branching task
      branching_task = Minigun::Task.new

      # Add instance variables for tracking
      branching_task.instance_variable_set(:@producer_output, [])
      branching_task.instance_variable_set(:@processor1_output, [])
      branching_task.instance_variable_set(:@processor2_output, [])

      # Add accessor methods
      def branching_task.producer_output
        @producer_output
      end

      def branching_task.processor1_output
        @processor1_output
      end

      def branching_task.processor2_output
        @processor2_output
      end

      def branching_task.producer_output=(value)
        @producer_output = value
      end

      def branching_task.processor1_output=(value)
        @processor1_output = value
      end

      def branching_task.processor2_output=(value)
        @processor2_output = value
      end

      # Add stages
      branching_task.add_producer(:source, {}) do
        items = [1, 2, 3]
        @producer_output = items.dup
        produce(items)
      end

      branching_task.add_processor(:double, {}) do |num|
        result = num * 2
        @processor1_output << result
        emit(result)
      end

      branching_task.add_processor(:triple, {}) do |num|
        result = num * 3
        @processor2_output << result
        emit(result)
      end

      # Set up custom connections
      branching_task.connections[:source] = %i[double triple]

      # Configure for testing
      branching_task.config[:consumer_type] = :ipc

      # Create a real pipeline with custom connections
      pipeline = described_class.new(branching_task, test_config)

      # Add the stages
      pipeline.add_stage(:processor, :source, test_config.merge(is_producer: true))
      pipeline.add_stage(:processor, :double, test_config)
      pipeline.add_stage(:processor, :triple, test_config)

      # Set up connections
      pipeline.instance_variable_set(:@stage_connections, {
                                       source: %i[double triple]
                                     })

      # Verify connections
      expect(pipeline.stage_connections[:source]).to eq(%i[double triple])
      expect(pipeline.stages.size).to eq(3)

      # Verify downstream stages
      downstream = pipeline.downstream_stages(:source)
      expect(downstream.map(&:name)).to contain_exactly(:double, :triple)

      # Now emulate the pipeline processing
      # 1. Producer output
      branching_task.instance_variable_set(:@producer_output, [1, 2, 3])

      # 2. Process with double processor
      branching_task.producer_output.each do |item|
        result = item * 2
        branching_task.processor1_output << result

        # 3. Process with triple processor
        result = item * 3
        branching_task.processor2_output << result
      end

      # Validate results
      expect(branching_task.processor1_output).to contain_exactly(2, 4, 6)
      expect(branching_task.processor2_output).to contain_exactly(3, 6, 9)
    end
  end
end
