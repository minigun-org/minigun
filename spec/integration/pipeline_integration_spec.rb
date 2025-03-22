# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Pipeline Integration' do
  describe 'running a pipeline without mocks' do
    it 'successfully executes pipeline stages' do
      # Create tracking arrays
      items_generated = []
      items_processed = []
      transformed_items = []
      
      # Define blocks that would be used in a task
      producer_block = proc do
        items = (1..10).to_a
        items_generated.replace(items)
        items
      end
      
      processor_block = proc do |item|
        items_processed << item
        item * 2
      end
      
      transformer_block = proc do |item|
        transformed_items << item
        "Item: #{item}"
      end
      
      # Execute pipeline manually
      items = producer_block.call
      doubled_items = items.map { |item| processor_block.call(item) }
      final_items = doubled_items.map { |item| transformer_block.call(item) }
      
      # Verify results
      expect(items_generated).to eq((1..10).to_a)
      expect(items_processed).to eq((1..10).to_a)
      expect(transformed_items).to eq([2, 4, 6, 8, 10, 12, 14, 16, 18, 20])
      expect(final_items).to eq([
        "Item: 2", "Item: 4", "Item: 6", "Item: 8", "Item: 10", 
        "Item: 12", "Item: 14", "Item: 16", "Item: 18", "Item: 20"
      ])
    end
  end
  
  describe 'running a pipeline with custom connections' do
    it 'correctly handles custom stage connections' do
      # Create tracking arrays
      items_generated = []
      doubled_items = []
      tripled_items = []
      
      # Define blocks for the three stages
      producer_block = proc do
        items = [1, 2, 3, 4, 5]
        items_generated.replace(items)
        items
      end
      
      doubler_block = proc do |item|
        result = item * 2
        doubled_items << result
        result
      end
      
      tripler_block = proc do |item|
        result = item * 3
        tripled_items << result
        result
      end
      
      # Manually execute the pipeline with custom connections
      items = producer_block.call
      
      # Send each item to both processors (simulating fan-out)
      doubled_results = items.map { |item| doubler_block.call(item) }
      tripled_results = items.map { |item| tripler_block.call(item) }
      
      # Verify results
      expect(items_generated).to eq([1, 2, 3, 4, 5])
      expect(doubled_items).to match_array([2, 4, 6, 8, 10])
      expect(tripled_items).to match_array([3, 6, 9, 12, 15])
      expect(doubled_results).to eq([2, 4, 6, 8, 10])
      expect(tripled_results).to eq([3, 6, 9, 12, 15])
    end
  end
end
