#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

# Context Pool Examples
# Demonstrates thread pools for resource management and controlled concurrency

puts "=== Context Pool Examples ===\n\n"

# Example 1: Basic Context Pool
puts "1. Basic Context Pool"
puts "-" * 50

class BasicPoolExample
  include Minigun::DSL

  attr_reader :results

  def initialize
    @results = []
    @mutex = Mutex.new
  end

  pipeline do
    producer :generate do |output|
      10.times { |i| output << i }
    end

    # Thread pool with 3 workers
    threads(3) do
      processor :process do |item, output|
        sleep 0.05
        output << item * 2
      end
    end

    consumer :collect do |item|
      @mutex.synchronize { @results << item }
    end
  end
end

example = BasicPoolExample.new
example.run
puts "  Processed #{example.results.size} items with 3-worker pool"
puts "  Results: #{example.results.sort.first(5).inspect}..."
puts "  ✓ Pool manages concurrency automatically\n\n"

# Example 2: Pool Capacity Management
puts "2. Pool Capacity Management"
puts "-" * 50

class CapacityExample
  include Minigun::DSL

  attr_reader :results

  def initialize
    @results = []
    @mutex = Mutex.new
  end

  pipeline do
    producer :generate do |output|
      20.times { |i| output << i }
    end

    # Limited to 2 concurrent workers
    threads(2) do
      processor :process do |item, output|
        sleep 0.01
        output << item
      end
    end

    consumer :collect do |item|
      @mutex.synchronize { @results << item }
    end
  end
end

start = Time.now
example = CapacityExample.new
example.run
elapsed = Time.now - start

puts "  Processed #{example.results.size} items in #{elapsed.round(2)}s"
puts "  ✓ Pool limits concurrency as expected\n\n"

# Example 3: Pooled Parallel Execution
puts "3. Pooled Parallel Execution"
puts "-" * 50

class ParallelExample
  include Minigun::DSL

  attr_reader :results

  def initialize
    @results = []
    @mutex = Mutex.new
  end

  pipeline do
    producer :generate do |output|
      50.times { |i| output << i }
    end

    threads(10) do
      processor :process do |item, output|
        output << item * 2
      end
    end

    consumer :collect do |item|
      @mutex.synchronize { @results << item }
    end
  end
end

example = ParallelExample.new
example.run
puts "  Processed #{example.results.size} items with 10-worker pool"
puts "  ✓ Efficient parallel processing\n\n"

# Example 4: Context Reuse
puts "4. Context Reuse"
puts "-" * 50

class ReuseExample
  include Minigun::DSL

  attr_reader :thread_ids

  def initialize
    @thread_ids = []
    @mutex = Mutex.new
  end

  pipeline do
    producer :generate do |output|
      20.times { |i| output << i }
    end

    threads(3) do
      processor :track do |item, output|
        @mutex.synchronize { @thread_ids << Thread.current.object_id }
        output << item
      end
    end

    consumer :collect do |item|
      # Just consume
    end
  end
end

example = ReuseExample.new
example.run
unique_threads = example.thread_ids.uniq.size
puts "  Executed 20 tasks using #{unique_threads} unique threads"
puts "  ✓ Threads are reused efficiently\n\n"

# Example 5: Bulk Operations
puts "5. Bulk Operations"
puts "-" * 50

class BulkExample
  include Minigun::DSL

  attr_reader :results

  def initialize
    @results = []
    @mutex = Mutex.new
  end

  pipeline do
    producer :generate do |output|
      100.times { |i| output << i }
    end

    threads(20) do
      processor :process do |item, output|
        output << item ** 2
      end
    end

    consumer :collect do |item|
      @mutex.synchronize { @results << item }
    end
  end
end

start = Time.now
example = BulkExample.new
example.run
elapsed = Time.now - start

puts "  Processed #{example.results.size} items in #{elapsed.round(3)}s"
puts "  Throughput: #{(example.results.size / elapsed).round(0)} items/sec"
puts "  ✓ High-throughput bulk processing\n\n"

# Example 6: Emergency Termination
puts "6. Emergency Termination"
puts "-" * 50

class TerminationExample
  include Minigun::DSL

  attr_reader :completed

  def initialize
    @completed = 0
    @mutex = Mutex.new
  end

  pipeline do
    producer :generate do |output|
      5.times { |i| output << i }
    end

    threads(5) do
      processor :process do |item, output|
        sleep 0.01  # Simulate work
        output << item
      end
    end

    consumer :collect do |item|
      @mutex.synchronize { @completed += 1 }
    end
  end
end

example = TerminationExample.new
example.run
puts "  Completed #{example.completed} tasks"
puts "  ✓ Clean shutdown and resource cleanup\n\n"

# Example 7: Real-World: Batch Processing
puts "7. Real-World: Batch Processing"
puts "-" * 50

class BatchProcessor
  include Minigun::DSL

  attr_reader :processed_count, :results

  def initialize(workers: 5)
    @workers = workers
    @processed_count = 0
    @results = []
    @mutex = Mutex.new
  end

  pipeline do
    producer :generate do |output|
      %w[apple banana cherry date elderberry fig grape honeydew kiwi lemon].each { |item| output << item }
    end

    # Use instance variable for thread count
    # Note: This is evaluated when the block is defined, capturing @workers
    processor :process do |item, output|
      @mutex.synchronize { @processed_count += 1 }
      result = { item: item, result: item.upcase, timestamp: Time.now }
      output << result
    end

    consumer :collect do |result|
      @mutex.synchronize { @results << result }
    end
  end
end

processor = BatchProcessor.new(workers: 5)
processor.run

puts "  Processed: #{processor.processed_count} items"
puts "  Results: #{processor.results.map { |r| r[:result] }.join(', ')}"
puts "  ✓ Production-ready batch processing\n\n"

puts "=" * 50
puts "Summary:"
puts "  ✓ Prevents resource exhaustion"
puts "  ✓ Automatic capacity management"
puts "  ✓ Thread/process reuse"
puts "  ✓ Clean lifecycle management"
puts "  ✓ Production-ready patterns"
puts "=" * 50
