#!/usr/bin/env ruby
# frozen_string_literal: true

# Example 110: Fiber with Batching
#
# Demonstrates using fibers with batch processing for efficient bulk operations

require_relative '../lib/minigun'

puts '=' * 60
puts 'Fiber with Batching'
puts '=' * 60

unless Minigun::Platform.async?
  puts "\n⚠️  The 'async' gem is not installed."
  exit 1
end

# Pipeline using fibers with batch processing for efficient bulk operations
class FiberBatching
  include Minigun::DSL

  attr_reader :results, :batch_sizes

  def initialize
    @results = []
    @batch_sizes = []
    @mutex = Mutex.new
  end

  pipeline do
    # Generate 100 items
    produce_each :items, (1..100).to_a

    # Batch items into groups of 10
    accumulator :batch, max_size: 10

    # Process batches concurrently with fibers
    in_fibers(5) do
      processor :batch_processor do |batch, output|
        @mutex.synchronize { @batch_sizes << batch.size }

        # Simulate bulk API call with the batch
        sleep 0.02

        # Process each item in batch
        batch.each do |item|
          output << { value: item, batch_processed: true, batch_size: batch.size }
        end
      end
    end

    # Optional: debatch back to individual items (already done above)
    # debatch

    consumer :collect do |item|
      @mutex.synchronize { @results << item }
    end
  end
end

start_time = Time.now
pipeline = FiberBatching.new
pipeline.run
elapsed = Time.now - start_time

puts "\nResults:"
puts "  Total items processed: #{pipeline.results.size}"
puts "  Batches processed: #{pipeline.batch_sizes.size}"
puts "  Batch sizes: #{pipeline.batch_sizes.uniq.join(', ')}"
puts "  All batch-processed: #{pipeline.results.all? { |r| r[:batch_processed] }}"
puts "  Elapsed: #{elapsed.round(3)}s"
puts "\n✓ Batching reduces number of concurrent operations"
puts '✓ Fibers handle batch I/O efficiently'
puts '✓ Perfect for bulk API calls, DB inserts'
