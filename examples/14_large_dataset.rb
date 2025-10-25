#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

# Large Dataset Processing Example
# Demonstrates processing 100+ items with concurrent threads
class LargeDatasetExample
  include Minigun::DSL

  max_threads 10      # High thread count for parallelism
  max_processes 2

  attr_accessor :results

  def initialize(item_count = 100)
    @item_count = item_count
    @results = []
    @mutex = Mutex.new
  end

  pipeline do
    producer :generate do
      puts "[Producer] Generating #{@item_count} items..."
      @item_count.times { |i| emit(i) }
      puts "[Producer] Done generating items"
    end

    consumer :collect do |item|
      @mutex.synchronize { results << item }

      # Log progress every 25 items
      if results.size % 25 == 0
        puts "[Consumer] Processed #{results.size}/#{@item_count} items..."
      end
    end
  end
end

if __FILE__ == $0
  puts "=== Large Dataset Processing Example ===\n\n"
  puts "This example demonstrates:"
  puts "  • Processing 100+ items efficiently"
  puts "  • Thread-safe collection with Mutex"
  puts "  • Concurrent processing with thread pool"
  puts "  • Progress tracking\n\n"

  item_count = 100
  example = LargeDatasetExample.new(item_count)

  puts "Configuration:"
  puts "  Items: #{item_count}"
  puts "  Max threads: #{example.class._minigun_task.config[:max_threads]}"
  puts "\n"

  start_time = Time.now
  example.run
  duration = Time.now - start_time

  puts "\n=== Results ===\n"
  puts "Total items processed: #{example.results.size}"
  puts "Duration: #{duration.round(3)}s"
  puts "Throughput: #{(example.results.size / duration).round(2)} items/sec"
  puts "All items unique: #{example.results.uniq.size == example.results.size ? '✓' : '✗'}"
  puts "No items lost: #{example.results.size == item_count ? '✓' : '✗'}"

  puts "\n=== Performance Tips ===\n"
  puts "• Increase max_threads for I/O-bound operations"
  puts "• Use Mutex for thread-safe shared data structures"
  puts "• For very large datasets (1M+), consider batching"
  puts "• Monitor memory usage with large in-memory collections"
  puts "\n✓ Large dataset processing complete!"
end

