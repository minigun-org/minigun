#!/usr/bin/env ruby
# frozen_string_literal: true

# Example 109: Fiber High Concurrency
#
# Demonstrates handling hundreds of concurrent operations with fibers
# This would be impractical with threads due to memory overhead

require_relative '../lib/minigun'

puts '=' * 60
puts 'Fiber High Concurrency'
puts '=' * 60

unless Minigun::Platform.async?
  puts "\n⚠️  The 'async' gem is not installed."
  exit 1
end

class FiberHighConcurrency
  include Minigun::DSL

  attr_reader :results, :max_concurrent

  def initialize
    @results = []
    @current_concurrent = 0
    @max_concurrent = 0
    @mutex = Mutex.new
  end

  pipeline do
    # Generate many items
    produce_each :items, (1..500).to_a

    # Use high fiber concurrency (100 concurrent fibers!)
    # Each fiber is only ~4KB vs ~1MB for threads
    in_fibers(100) do
      processor :async_operation do |item, output|
        # Track concurrency
        @mutex.synchronize do
          @current_concurrent += 1
          @max_concurrent = [@max_concurrent, @current_concurrent].max
        end

        # Simulate async I/O (e.g., HTTP request, DB query)
        sleep 0.01

        @mutex.synchronize { @current_concurrent -= 1 }

        output << { value: item, processed_at: Time.now.to_f }
      end
    end

    consumer :collect do |item|
      @mutex.synchronize { @results << item }
    end
  end
end

puts "\nProcessing 500 items with up to 100 concurrent fibers..."
puts "Memory overhead: ~400KB for fibers vs ~100MB for threads\n"

start_time = Time.now
pipeline = FiberHighConcurrency.new
pipeline.run
elapsed = Time.now - start_time

puts "\nResults:"
puts "  Processed: #{pipeline.results.size} items"
puts "  Max concurrent fibers: #{pipeline.max_concurrent}"
puts "  Throughput: #{(pipeline.results.size / elapsed).round(1)} items/sec"
puts "  Elapsed: #{elapsed.round(3)}s"
puts "\n✓ 100 concurrent fibers with minimal memory"
puts "✓ High throughput for I/O-bound workloads"

# Estimate memory savings
fiber_memory = 100 * 4  # ~4KB per fiber
thread_memory = 100 * 1024  # ~1MB per thread
puts "✓ Memory savings: ~#{thread_memory / 1024}MB (threads) vs ~#{fiber_memory / 1024}MB (fibers)"
