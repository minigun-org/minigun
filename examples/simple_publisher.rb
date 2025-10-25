# frozen_string_literal: true

require 'minigun'

# Simple example demonstrating the publisher pattern
class SimplePublisher
  include Minigun::DSL

  # Configuration
  max_threads 3
  max_processes 2

  def initialize(items:)
    @items = items
  end

  # Define the pipeline
  pipeline do
    # Producer: Generate IDs
    producer :fetch_ids do
      @items.each do |item|
        emit(item)
      end
    end

    # Processor: Transform items
    processor :transform do |item|
      result = item * 2
      emit(result)
    end

    # Accumulator: Batch items
    accumulator :batch_items do |item|
      @batch ||= []
      @batch << item

      if @batch.size >= 5
        batch_copy = @batch.dup
        @batch.clear
        emit(batch_copy)
      end
    end

    # Consumer: Process batches (in forked process)
    cow_fork :process_batch, processes: 2 do |batch|
      puts "Processing batch of #{batch.size} items: #{batch.inspect}"
      batch.each { |item| puts "  - Processed: #{item}" }
    end
  end
end

# Run the publisher
if __FILE__ == $PROGRAM_NAME
  publisher = SimplePublisher.new(items: (1..20).to_a)
  publisher.run
end

