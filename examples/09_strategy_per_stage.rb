#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

# Stage-Level Strategy Example
# Demonstrates different execution strategies for different stages
class StrategyPerStageExample
  include Minigun::DSL

  attr_accessor :results, :thread_results, :fork_results

  def initialize
    @results = []
    @thread_results = []
    @fork_results = []
    @mutex = Mutex.new
  end

  producer :generate do
    puts "[Producer] Generating 10 items"
    10.times { |i| emit(i + 1) }
  end

  # Light processor uses threads (default)
  processor :validate, strategy: :threaded do |num|
    puts "[Validator:threaded] Validating #{num}"
    emit(num) if num > 0
  end

  # Heavy consumer uses fork_accumulate (COW fork pattern)
  consumer :heavy_save,
           strategy: :fork_accumulate,
           accumulator_max_single: 3 do |num|
    puts "[HeavySave:fork_accumulate:#{Process.pid}] Processing #{num}"
    sleep 0.01  # Simulate heavy work
    @mutex.synchronize { fork_results << num }
  end

  # Light consumer uses threads
  consumer :light_log, strategy: :threaded do |num|
    puts "[LightLog:threaded] Logging #{num}"
    @mutex.synchronize { thread_results << num }
  end
end

if __FILE__ == $0
  puts "=== Strategy Per Stage Example ===\n\n"
  puts "Producer → Validator (threaded) → [HeavySave (fork_accumulate), LightLog (threaded)]\n\n"

  example = StrategyPerStageExample.new
  example.run

  puts "\n=== Results ===\n"
  puts "Fork Results: #{example.fork_results.sort.inspect}"
  puts "Thread Results: #{example.thread_results.sort.inspect}"
  puts "Total: #{example.fork_results.size + example.thread_results.size} items processed"

  success = example.fork_results.sort == (1..10).to_a &&
            example.thread_results.sort == (1..10).to_a
  puts success ? "✓ Success!" : "✗ Check results"
end

