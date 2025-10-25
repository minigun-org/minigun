#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

# Configuration Example
# Demonstrates all available configuration options
class ConfigurationExample
  include Minigun::DSL

  # Thread pool size for concurrent processing
  # Higher = more parallelism, but also more memory/CPU
  max_threads 10

  # Maximum number of forked processes (for fork_accumulate strategy)
  # Higher = more parallel batch processing
  max_processes 4

  # Maximum retry attempts for failed operations
  # (Currently not fully implemented in the framework)
  max_retries 5

  attr_accessor :results

  def initialize
    @results = []
    @mutex = Mutex.new
  end

  pipeline do
    producer :generate do
      puts "[Producer] Generating 20 items..."
      20.times { |i| emit(i + 1) }
    end

    processor :validate do |item|
      # Simulate validation with occasional failure
      if item % 7 == 0
        puts "[Processor] Skipping invalid item: #{item}"
        # Don't emit - this stops the item from propagating
      else
        emit(item)
      end
    end

    processor :transform do |item|
      # Simulate some work
      result = item * 2
      puts "[Processor] Transformed #{item} -> #{result}"
      emit(result)
    end

    consumer :collect do |item|
      @mutex.synchronize { results << item }
      puts "[Consumer] Collected: #{item}"
    end
  end
end

if __FILE__ == $0
  puts "=== Configuration Example ===\n\n"

  puts "Available Configuration Options:"
  puts "  max_threads(n)    - Thread pool size for concurrent processing"
  puts "  max_processes(n)  - Max forked processes (fork_accumulate strategy)"
  puts "  max_retries(n)    - Max retry attempts for failed operations"
  puts "\n"

  example = ConfigurationExample.new

  # Access the underlying task configuration
  task = ConfigurationExample._minigun_task

  puts "Current Configuration:"
  puts "  max_threads:   #{task.config[:max_threads]}"
  puts "  max_processes: #{task.config[:max_processes]}"
  puts "  max_retries:   #{task.config[:max_retries]}"
  puts "\n"

  puts "Running pipeline with these settings...\n\n"

  result = example.run

  puts "\n=== Results ===\n"
  puts "Total items emitted by producer: 20"
  puts "Items filtered out (multiples of 7): #{[7, 14].size}"
  puts "Items successfully processed: #{example.results.size}"
  puts "Expected: #{20 - 2} items (20 minus 2 filtered)"
  puts "Actual: #{example.results.size} items"
  puts "\nFirst 10 results: #{example.results.first(10).inspect}"

  puts "\n=== Configuration Tips ===\n"
  puts "• max_threads: Set higher for I/O-bound work (network, database)"
  puts "• max_threads: Set lower for CPU-bound work to avoid context switching"
  puts "• max_processes: Useful with fork_accumulate for memory-intensive batches"
  puts "• max_processes: Each process is a separate OS process (more isolation)"
  puts "• Balance threads vs processes based on your workload characteristics"
  puts "\n✓ Configuration example complete!"
end

