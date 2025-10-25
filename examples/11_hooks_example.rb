#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

# Hooks Example
# Demonstrates lifecycle hooks: before_run, after_run, before_fork, after_fork
class HooksExample
  include Minigun::DSL

  attr_accessor :events, :results

  def initialize
    @events = []
    @results = []
  end

  # Hook: Called before the pipeline starts
  before_run do
    puts "[Hook] before_run - Setting up resources..."
    events << :before_run

    # Example: Open database connections, initialize caches, etc.
    @start_time = Time.now
  end

  # Hook: Called after the pipeline completes
  after_run do
    puts "[Hook] after_run - Cleaning up resources..."
    events << :after_run

    # Example: Close database connections, write final logs, etc.
    duration = Time.now - @start_time
    puts "[Hook] Pipeline completed in #{duration.round(3)}s"
  end

  # Hook: Called before forking a process (COW fork strategy)
  before_fork do
    puts "[Hook] before_fork - Preparing to fork..."
    events << :before_fork

    # Example: Close database connections before fork to avoid shared sockets
    # Important for COW forking to prevent connection issues
  end

  # Hook: Called after forking a process (in the child process)
  after_fork do
    puts "[Hook] after_fork (child process: #{Process.pid})"
    events << :after_fork

    # Example: Reopen database connections in child process
    # Each forked process needs its own connection
  end

  pipeline do
    producer :generate do
      puts "[Producer] Generating 5 items..."
      5.times { |i| emit(i + 1) }
    end

    processor :transform do |item|
      puts "[Processor] Processing item #{item}"
      # Simulate some work
      sleep 0.05
      emit(item * 10)
    end

    consumer :collect do |item|
      puts "[Consumer] Collecting result: #{item}"
      results << item
    end
  end
end

if __FILE__ == $0
  puts "=== Hooks Example ===\n\n"
  puts "This example demonstrates the 4 lifecycle hooks:\n"
  puts "  1. before_run  - Called before pipeline starts"
  puts "  2. after_run   - Called after pipeline completes"
  puts "  3. before_fork - Called before forking (COW strategy only)"
  puts "  4. after_fork  - Called after forking (COW strategy only)\n\n"

  example = HooksExample.new
  example.run

  puts "\n=== Results ===\n"
  puts "Hooks called: #{example.events.inspect}"
  puts "Items processed: #{example.results.size}"
  puts "Results: #{example.results.inspect}"

  puts "\n=== Notes ===\n"
  puts "• before_fork/after_fork hooks are only triggered with spawn_fork strategy"
  puts "• Hooks are useful for resource management (connections, files, etc.)"
  puts "• after_fork runs in the child process, before_fork in the parent"
  puts "\n✓ Hooks demonstration complete!"
end

