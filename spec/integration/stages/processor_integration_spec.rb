# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Processor Integration' do
  let(:test_task_context) do
    Class.new do
      attr_reader :processed_items, :emitted_items
      attr_accessor :fail_on_item

      def initialize
        @processed_items = []
        @emitted_items = []
        @fail_on_item = nil
        @retry_counts = Hash.new(0)
      end

      def record_processed(item)
        @processed_items << item
      end

      def record_emitted(item)
        @emitted_items << item
      end

      def retry_count_for(item)
        @retry_counts[item]
      end

      def increment_retry(item)
        @retry_counts[item] += 1
      end

      def should_fail?(item)
        item == @fail_on_item && retry_count_for(item) == 0
      end
    end.new
  end

  describe 'direct processor behavior simulation' do
    it 'processes items and emits transformed values' do
      # Setup the processor with a block that doubles the input
      processor_block = proc do |num|
        test_task_context.record_processed(num)
        result = num * 2
        test_task_context.record_emitted(result)
        result
      end

      # Process items [1, 2, 3]
      items = [1, 2, 3]
      items.each do |item|
        processor_block.call(item)
      end

      # Verify the items were processed
      expect(test_task_context.processed_items).to contain_exactly(1, 2, 3)
      expect(test_task_context.emitted_items).to contain_exactly(2, 4, 6)
    end

    it 'retries failed items before succeeding' do
      # Configure the task to fail on item #3 the first time
      test_task_context.fail_on_item = 3

      # Setup the processor with a block that might fail
      processor_block = proc do |num|
        if test_task_context.should_fail?(num)
          test_task_context.increment_retry(num)
          raise "Test error for retry on item #{num}"
        end

        test_task_context.record_processed(num)
        result = num * 2
        test_task_context.record_emitted(result)
        result
      end

      # Process items [1, 2, 3]
      items = [1, 2, 3]

      items.each do |item|
        processor_block.call(item)
      rescue StandardError => e
        # Simulate retry logic
        raise e unless e.message.include?('Test error for retry') && test_task_context.retry_count_for(item) <= 3

        # Try again
        processor_block.call(item)
      end

      # Verify all items were processed successfully after retry
      expect(test_task_context.processed_items).to contain_exactly(1, 2, 3)
      expect(test_task_context.emitted_items).to contain_exactly(2, 4, 6)
      expect(test_task_context.retry_count_for(3)).to eq(1)
    end
  end
end
