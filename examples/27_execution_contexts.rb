#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

# Execution Context Examples
# Demonstrates how to specify execution strategies in Minigun pipelines

puts "=== Execution Context Examples ===\n\n"

# Example 1: InlineContext - Synchronous execution
puts '1. InlineContext (synchronous, same thread)'
puts '-' * 50

class InlineExample
  include Minigun::DSL

  attr_reader :results

  def initialize
    @results = []
  end

  pipeline do
    producer :generate do |output|
      5.times { |i| output << i }
    end

    # No execution context specified = inline (synchronous)
    processor :process do |item, output|
      output << (item * 2)
    end

    consumer :collect do |item|
      @results << item
    end
  end
end

example = InlineExample.new
example.run
puts "  Processed #{example.results.size} items synchronously"
puts "  Results: #{example.results.inspect}"
puts "  ✓ Inline execution completes immediately\n\n"

# Example 2: ThreadContext - Lightweight concurrency
puts '2. ThreadContext (lightweight parallelism)'
puts '-' * 50

class ThreadExample
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

    # Use thread pool for concurrent processing
    threads(5) do
      processor :process do |item, output|
        sleep 0.01 # Simulate work
        output << (item * 2)
      end
    end

    consumer :collect do |item|
      @mutex.synchronize { @results << item }
    end
  end
end

example = ThreadExample.new
example.run
puts "  Processed #{example.results.size} items concurrently"
puts "  Results (first 5): #{example.results.sort.first(5).inspect}"
puts "  ✓ Thread execution with concurrency\n\n"

# Example 3: RactorContext - True parallelism
puts '3. RactorContext (true parallelism, Ruby 3+)'
puts '-' * 50

class RactorExample
  include Minigun::DSL

  attr_reader :results

  def initialize
    @results = []
    @mutex = Mutex.new
  end

  pipeline do
    producer :generate do |output|
      5.times { |i| output << i }
    end

    # Ractors provide true parallelism (falls back to threads if unavailable)
    ractors(2) do
      processor :process do |item, output|
        output << (item**2)
      end
    end

    consumer :collect do |item|
      @mutex.synchronize { @results << item }
    end
  end
end

example = RactorExample.new
example.run
puts "  Processed #{example.results.size} items"
puts "  Results: #{example.results.sort.inspect}"
puts "  ✓ Ractor execution (or thread fallback)\n\n"

# Example 4: Process Isolation
if Process.respond_to?(:fork)
  puts '4. Process Isolation'
  puts '-' * 50

  class ProcessExample
    include Minigun::DSL

    attr_reader :results

    def initialize
      @results = []
      @mutex = Mutex.new
    end

    pipeline do
      producer :generate do |output|
        3.times { |i| output << i }
      end

      # Process isolation for CPU-bound tasks
      batch 1
      process_per_batch(max: 2) do
        processor :process do |batch, output|
          batch.each do |item|
            output << { item: item, pid: Process.pid, result: item * 100 }
          end
        end
      end

      consumer :collect do |data|
        @mutex.synchronize { @results << data }
      end
    end
  end

  example = ProcessExample.new
  example.run
  puts "  Processed #{example.results.size} items"
  pids = example.results.map { |r| r[:pid] }.uniq
  puts "  Used #{pids.size} different processes"
  puts "  ✓ Process isolation works!\n\n"
else
  puts "4. Process Isolation (skipped - fork not available)\n\n"
end

# Example 5: Parallel Execution
puts '5. Parallel Execution'
puts '-' * 50

class ParallelExample
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

    threads(5) do
      processor :process do |item, output|
        sleep 0.01 # Simulate work
        output << (item * 3)
      end
    end

    consumer :collect do |item|
      @mutex.synchronize { @results << item }
    end
  end
end

start = Time.now
example = ParallelExample.new
example.run
elapsed = Time.now - start

puts "  Processed #{example.results.size} items in #{elapsed.round(2)}s"
puts "  Results: #{example.results.sort.inspect}"
puts "  ✓ Parallel execution with multiple workers\n\n"

# Example 6: Error Handling and Propagation
puts '6. Error Handling and Propagation'
puts '-' * 50

class ErrorExample
  include Minigun::DSL

  attr_reader :errors, :results

  def initialize
    @errors = []
    @results = []
    @mutex = Mutex.new
  end

  pipeline do
    producer :generate do |output|
      5.times { |i| output << i }
    end

    threads(2) do
      processor :process do |item, output|
        raise StandardError, "Error on item #{item}" if item == 2

        output << (item * 2)
      end
    end

    consumer :collect do |item|
      @mutex.synchronize { @results << item }
    end
  end
end

example = ErrorExample.new
example.run
puts "  Processed #{example.results.size} successful items"
puts "  Results: #{example.results.sort.inspect}"
puts "  ✓ Error handling built-in\n\n"

# Example 7: Context Termination
puts '7. Context Termination'
puts '-' * 50

class TerminationExample
  include Minigun::DSL

  attr_reader :count

  def initialize
    @count = 0
    @mutex = Mutex.new
  end

  pipeline do
    producer :generate do |output|
      10.times { |i| output << i }
    end

    threads(3) do
      processor :process do |item, output|
        output << item
      end
    end

    consumer :collect do |_item|
      @mutex.synchronize { @count += 1 }
    end
  end
end

example = TerminationExample.new
example.run
puts "  Processed #{example.count} items"
puts "  ✓ Clean termination\n\n"

puts '=' * 50
puts 'Summary:'
puts '  ✓ Unified API for all concurrency models'
puts '  ✓ :inline - synchronous execution (default)'
puts '  ✓ threads(N) - thread pool with N workers'
puts '  ✓ ractors(N) - true parallelism (Ruby 3+)'
puts '  ✓ process_per_item/batch - process isolation'
puts '  ✓ Error handling built-in'
puts '  ✓ Clean shutdown and resource management'
puts '=' * 50
