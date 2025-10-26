#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'
require 'tempfile'
require 'json'

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
    @temp_file = Tempfile.new(['minigun_fork_results', '.json'])
    @temp_file.close
  end

  def cleanup
    File.unlink(@temp_file.path) if @temp_file && File.exist?(@temp_file.path)
  end

  pipeline do
    producer :generate do
      puts "[Producer] Generating 10 items"
      10.times { |i| emit(i + 1) }
    end

    # Light processor uses threads (default)
    processor :validate, to: :batch do |num|
      puts "[Validator] Validating #{num}"
      emit(num) if num > 0
    end

    # Accumulator batches items before spawning workers
    accumulator :batch, max_size: 3, to: [:heavy_save, :light_log]

    # Heavy consumer spawns forks per batch (COW fork pattern)
    process_per_batch(max: 2) do
      consumer :heavy_save do |batch|
        puts "[HeavySave:process_per_batch:#{Process.pid}] Processing batch of #{batch.size}"
        sleep 0.01  # Simulate heavy work
        
        # Write results to temp file (fork-safe)
        File.open(@temp_file.path, 'a') do |f|
          f.flock(File::LOCK_EX)
          batch.each { |num| f.puts(num) }
          f.flock(File::LOCK_UN)
        end
      end
    end

    # Light consumer uses threads (stream mode, no batching needed)
    threads(5) do
      consumer :light_log do |batch|
        puts "[LightLog:threads] Logging batch of #{batch.size}"
        batch.each { |num| @mutex.synchronize { thread_results << num } }
      end
    end
    
    after_run do
      # Read fork results from temp file
      if File.exist?(@temp_file.path)
        @fork_results = File.readlines(@temp_file.path).map { |line| line.strip.to_i }
      end
    end
  end
end

if __FILE__ == $0
  puts "=== Strategy Per Stage Example ===\n\n"
  puts "Producer → Validator → Batch (accumulator) → [HeavySave (process_per_batch), LightLog (threads)]\n\n"

  example = StrategyPerStageExample.new
  begin
    example.run

    puts "\n=== Results ===\n"
    puts "Fork Results: #{example.fork_results.sort.inspect}"
    puts "Thread Results: #{example.thread_results.sort.inspect}"
    puts "Total: #{example.fork_results.size + example.thread_results.size} items processed"

    success = example.fork_results.sort == (1..10).to_a &&
              example.thread_results.sort == (1..10).to_a
    puts success ? "✓ Success!" : "✗ Check results"
  ensure
    example.cleanup
  end
end

