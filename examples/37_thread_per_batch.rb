#!/usr/bin/env ruby
# frozen_string_literal: true

# Example 37: Thread Per Batch Pattern
#
# Demonstrates spawning a new thread for each batch instead of using a pool
# Useful for batch-level parallelism with shared memory

require_relative '../lib/minigun'

puts '=' * 60
puts 'Thread Per Batch Pattern'
puts '=' * 60

class ThreadPerBatchExample
  include Minigun::DSL

  attr_reader :batch_threads, :results

  def initialize
    @batch_threads = []
    @results = []
    @mutex = Mutex.new
  end

  pipeline do
    producer :gen do |output|
      100.times { |i| output << i }
    end

    batch 20

    # Spawn a new thread for each batch
    thread_per_batch(max: 5) do
      consumer :process_batch do |batch|
        thread_id = Thread.current.object_id

        @mutex.synchronize do
          @batch_threads << thread_id
        end

        # Process batch in its own thread
        processed = batch.map { |x| x * 2 }
        @mutex.synchronize { @results.concat(processed) }
      end
    end
  end
end

pipeline = ThreadPerBatchExample.new
pipeline.run

puts "\nResults:"
puts "  Processed: #{pipeline.results.size} items"
puts "  Batches: #{pipeline.batch_threads.size}"
puts "  Unique threads: #{pipeline.batch_threads.uniq.size}"
puts "\n✓ Each batch in its own thread"
puts '✓ Max 5 concurrent threads enforced'
puts '✓ Good for batch-level parallelism'
puts '✓ Shared memory across threads'

puts "\n#{'=' * 60}"
puts 'Example 2: Mixed Thread Pool and Thread Per Batch'
puts '=' * 60

class MixedThreading
  include Minigun::DSL

  attr_reader :results

  def initialize
    @results = []
    @mutex = Mutex.new
  end

  pipeline do
    producer :gen do |output|
      50.times { |i| output << i }
    end

    # Thread pool for individual items
    threads(10) do
      processor :fetch do |item, output|
        output << (item * 2)
      end

      processor :validate do |item, output|
        output << item
      end
    end

    # Batch for efficient processing
    batch 10

    # Spawn thread per batch for batch-level work
    thread_per_batch(max: 3) do
      consumer :process_batch do |batch|
        # Each batch processed in isolation
        result = batch.sum
        @mutex.synchronize { @results << result }
      end
    end
  end
end

pipeline = MixedThreading.new
pipeline.run

puts "\nResults:"
puts "  Batch results: #{pipeline.results.size}"
puts "  Sum of sums: #{pipeline.results.sum}"
puts "\n✓ Thread pool for item processing"
puts '✓ Thread per batch for batch aggregation'
puts '✓ Mix strategies within one pipeline'
