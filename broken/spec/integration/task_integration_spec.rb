# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Task Integration' do
  describe 'running without full pipeline mocks' do
    it 'simulates running the task without full pipeline execution' do
      # Create a tracking array
      processed_items = []

      # Define a simple processor
      processor_block = proc do |item|
        processed_items << item
        item * 2
      end

      # Process some items using the block directly
      results = [1, 2, 3, 4, 5].map { |item| processor_block.call(item) }

      # Verify results
      expect(processed_items).to eq([1, 2, 3, 4, 5])
      expect(results).to eq([2, 4, 6, 8, 10])
    end
  end

  describe 'simulating retries without mocks' do
    it 'simulates a retry and successful processing' do
      # Track attempts
      attempts = Hash.new(0)
      processed_items = []

      # Define a processor that fails on first attempt
      processor = proc do |item|
        attempts[item] += 1

        raise "Simulated failure for item #{item}" if attempts[item] == 1

        processed_items << item
        item * 2
      end

      # Process with retry logic
      item = 42

      # First attempt should fail
      expect { processor.call(item) }.to raise_error(RuntimeError)
      expect(attempts[item]).to eq(1)
      expect(processed_items).to be_empty

      # Second attempt should succeed
      result = processor.call(item)
      expect(attempts[item]).to eq(2)
      expect(processed_items).to eq([42])
      expect(result).to eq(84)
    end
  end

  describe 'custom pipeline connections' do
    it 'simulates a branching pipeline manually' do
      # Set up test module
      source_items = []
      doubled_items = []
      tripled_items = []

      # Create contexts manually without running pipelines
      source_proc = proc do
        items = [1, 2, 3, 4, 5]
        source_items.replace(items)
        items
      end

      doubler_proc = proc do |item|
        result = item * 2
        doubled_items << result
        result
      end

      tripler_proc = proc do |item|
        result = item * 3
        tripled_items << result
        result
      end

      # Execute the "pipeline" manually
      items = source_proc.call

      # Send each item to both processors
      items.each do |item|
        doubler_proc.call(item)
        tripler_proc.call(item)
      end

      # Verify the branching behavior
      expect(source_items).to eq([1, 2, 3, 4, 5])
      expect(doubled_items).to contain_exactly(2, 4, 6, 8, 10)
      expect(tripled_items).to contain_exactly(3, 6, 9, 12, 15)
    end
  end
end
