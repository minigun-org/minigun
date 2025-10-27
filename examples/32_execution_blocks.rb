#!/usr/bin/env ruby
# frozen_string_literal: true

# Example 32: Execution Block Syntax (Refactor 2)
#
# This example demonstrates the new execution block syntax that replaces
# the old strategy-based system with clear, composable execution contexts.
#
# Key Features:
# - threads(N) { ... } - Thread pool for stages within block
# - processes(N) { ... } - Process pool for stages within block
# - ractors(N) { ... } - Ractor pool for stages within block
# - batch N - Accumulator stage
# - process_per_batch(max: N) { ... } - Spawn process per batch
# - thread_per_batch(max: N) { ... } - Spawn thread per batch
# - Composable nesting with proper context inheritance

require_relative '../lib/minigun'

puts '=' * 60
puts 'Example 1: Basic Thread Pool'
puts '=' * 60

class ThreadPoolExample
  include Minigun::DSL

  attr_reader :results

  def initialize
    @results = []
    @mutex = Mutex.new
  end

  pipeline do
    producer :gen do |output|
      10.times { |i| output << i }
    end

    # All stages within threads block use thread pool of 5
    threads(5) do
      processor :double do |item, output|
        output << (item * 2)
      end

      processor :add_ten do |item, output|
        output << (item + 10)
      end

      consumer :collect do |item|
        @mutex.synchronize { @results << item }
      end
    end
  end
end

pipeline = ThreadPoolExample.new
pipeline.run
puts "Results: #{pipeline.results.sort}"
puts "✓ All stages executed in thread pool of 5\n\n"

# Example 2: Batching with Process Per Batch
puts '=' * 60
puts 'Example 2: Batch + Process Per Batch'
puts '=' * 60

class BatchProcessExample
  include Minigun::DSL

  attr_reader :processed

  def initialize
    @processed = []
    @mutex = Mutex.new
  end

  pipeline do
    producer :gen do |output|
      100.times { |i| output << i }
    end

    threads(10) do
      processor :download do |item, output|
        # Simulate I/O-bound work
        output << { id: item, data: "data-#{item}" }
      end
    end

    # Accumulate into batches of 20
    batch 20

    # Spawn a new process for each batch (max 4 concurrent)
    process_per_batch(max: 4) do
      consumer :process_batch do |batch|
        @mutex.synchronize do
          @processed << { pid: Process.pid, size: batch.size }
        end
      end
    end
  end
end

pipeline = BatchProcessExample.new
pipeline.run
puts "Processed #{pipeline.processed.size} batches"
puts "PIDs: #{pipeline.processed.map { |p| p[:pid] }.uniq.join(', ')}"
puts "✓ Batched and processed in separate processes\n\n"

# Example 3: Nested Execution Contexts
puts '=' * 60
puts 'Example 3: Nested Contexts'
puts '=' * 60

class NestedContextExample
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

    # Outer: thread pool for I/O work
    threads(20) do
      processor :fetch do |item, output|
        # Simulate fetch
        output << (item * 2)
      end

      # Batch within thread context
      batch 10

      # Inner: process per batch for CPU work
      process_per_batch(max: 3) do
        processor :compute do |batch, _output|
          # CPU-intensive work in isolated process
          batch.map { |x| x**2 }
        end
      end

      # Back to thread context after process_per_batch
      consumer :save do |results|
        @mutex.synchronize { @results.concat(results) }
      end
    end
  end
end

pipeline = NestedContextExample.new
pipeline.run
puts "Processed #{pipeline.results.size} items"
puts "✓ Nested contexts work correctly\n\n"

# Example 4: Named Execution Contexts
puts '=' * 60
puts 'Example 4: Named Execution Contexts'
puts '=' * 60

class NamedContextExample
  include Minigun::DSL

  attr_reader :io_results, :cpu_results

  def initialize
    @io_results = []
    @cpu_results = []
    @mutex = Mutex.new
  end

  pipeline do
    # Define named contexts
    execution_context :io_pool, :threads, 50
    execution_context :cpu_pool, :processes, 4

    producer :gen do |output|
      20.times { |i| output << i }
    end

    # Use named context
    processor :download, execution_context: :io_pool do |item, output|
      output << { id: item, data: 'downloaded' }
    end

    # Use different named context
    processor :compute, execution_context: :cpu_pool do |item, output|
      output << item[:data].upcase
    end

    consumer :collect do |item|
      @mutex.synchronize { @cpu_results << item }
    end
  end
end

pipeline = NamedContextExample.new
pipeline.run
puts "Results: #{pipeline.cpu_results.size} items"
puts "✓ Named contexts allow flexible assignment\n\n"

# Example 5: Complex Real-World Pipeline
puts '=' * 60
puts 'Example 5: Complex Real-World Pipeline'
puts '=' * 60

class ComplexPipeline
  include Minigun::DSL

  attr_reader :saved_count

  def initialize
    @saved_count = 0
    @mutex = Mutex.new
  end

  pipeline do
    # Generate URLs
    producer :generate_urls do |output|
      100.times { |i| output << "https://example.com/page-#{i}" }
    end

    # Download in parallel with threads (I/O-bound)
    threads(50) do
      processor :download do |url, output|
        # Simulate HTTP request
        output << { url: url, html: '<html>content</html>', size: 1024 }
      end

      processor :extract do |page, output|
        # Extract data from HTML
        output << { url: page[:url], title: 'Page', links: 10 }
      end
    end

    # Batch for efficient processing
    batch 20

    # Parse in separate processes (CPU-bound)
    process_per_batch(max: 4) do
      processor :parse_batch do |batch, _output|
        # CPU-intensive parsing
        batch.map do |page|
          {
            url: page[:url],
            parsed: true,
            timestamp: Time.now.to_i
          }
        end
      end
    end

    # Save results (back to threads)
    threads(10) do
      consumer :save_to_db do |results|
        @mutex.synchronize { @saved_count += results.size }
      end
    end
  end
end

pipeline = ComplexPipeline.new
pipeline.run
puts "Saved #{pipeline.saved_count} results"
puts "✓ Complex pipeline with multiple execution contexts\n\n"

# Example 6: Thread Per Batch
puts '=' * 60
puts 'Example 6: Thread Per Batch'
puts '=' * 60

class ThreadPerBatchExample
  include Minigun::DSL

  attr_reader :batch_count

  def initialize
    @batch_count = 0
    @mutex = Mutex.new
  end

  pipeline do
    producer :gen do |output|
      50.times { |i| output << i }
    end

    batch 10

    # Spawn a new thread for each batch
    thread_per_batch(max: 5) do
      consumer :process do |_batch|
        @mutex.synchronize { @batch_count += 1 }
      end
    end
  end
end

pipeline = ThreadPerBatchExample.new
pipeline.run
puts "Processed #{pipeline.batch_count} batches"
puts "✓ Thread per batch with max concurrency limit\n\n"

# Summary
puts '=' * 60
puts 'Summary'
puts '=' * 60
puts <<~SUMMARY

  Execution Block Syntax:

  1. Thread Pools:
     threads(N) do ... end
     - Reuses N threads for all stages in block
     - Good for I/O-bound work

  2. Process Pools:
     processes(N) do ... end
     - Reuses N processes for all stages in block
     - Good for CPU-bound work with isolation

  3. Ractor Pools:
     ractors(N) do ... end
     - Reuses N ractors for all stages in block
     - True parallelism (Ruby 3.0+)

  4. Batching:
     batch N
     - Accumulates N items before passing to next stage

  5. Per-Batch Spawning:
     process_per_batch(max: N) do ... end
     - Spawns new process for each batch
     - Max N concurrent processes
     - Copy-on-write optimization

     thread_per_batch(max: N) do ... end
     - Spawns new thread for each batch
     - Max N concurrent threads

  6. Named Contexts:
     execution_context :name, :threads, N
     processor :stage, execution_context: :name
     - Define reusable named contexts
     - Assign to specific stages

  7. Nesting:
     - Contexts can nest naturally
     - Inner contexts override outer contexts
     - Batch creates accumulator stage
     - Clean, composable design

  Benefits:
  ✓ Clear intent (what, not how)
  ✓ Composable blocks
  ✓ Natural nesting
  ✓ No strategy: options
  ✓ Runtime configurable
  ✓ Type-safe context management
SUMMARY
