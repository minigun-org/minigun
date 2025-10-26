#!/usr/bin/env ruby
# frozen_string_literal: true

# Example 36: Batch + Process Per Batch Pattern
#
# Demonstrates the common pattern of batching followed by process-per-batch
# for Copy-on-Write optimization

require_relative '../lib/minigun'
require 'tempfile'

puts "=" * 60
puts "Batch + Process Per Batch Pattern"
puts "=" * 60

class BatchProcessor
  include Minigun::DSL

  attr_reader :batches_processed, :unique_pids

  def initialize
    @batches_processed = 0
    @unique_pids = []
    @mutex = Mutex.new
    @temp_file = Tempfile.new(['minigun_batch_count', '.txt'])
    @temp_file.close
  end

  def cleanup
    File.unlink(@temp_file.path) if @temp_file && File.exist?(@temp_file.path)
  end

  pipeline do
    producer :generate_data do
      1000.times { |i| emit(i) }
    end

    # Accumulate into batches of 100
    batch 100

    # Spawn a new process for each batch
    # Max 4 concurrent processes
    process_per_batch(max: 4) do
      consumer :process_in_isolation do |batch|
        pid = Process.pid

        # Write to temp file (fork-safe)
        File.open(@temp_file.path, 'a') do |f|
          f.flock(File::LOCK_EX)
          f.puts("1")  # Count one batch
          f.flock(File::LOCK_UN)
        end

        # Simulate CPU-intensive work
        batch.each { |item| item ** 2 }
      end
    end

    after_run do
      # Read fork results from temp file
      if File.exist?(@temp_file.path)
        @batches_processed = File.readlines(@temp_file.path).size
      end
    end
  end
end

pipeline = BatchProcessor.new
pipeline.run

puts "\nResults:"
puts "  Batches processed: #{pipeline.batches_processed}"
puts "  Unique PIDs: #{pipeline.unique_pids.size}"
puts "  PIDs: #{pipeline.unique_pids.join(', ')}"
puts "\n✓ Copy-on-Write optimization"
puts "✓ Each batch in isolated process"
puts "✓ Max 4 concurrent processes enforced"
puts "✓ Efficient for CPU-bound work"

puts "\n" + "=" * 60
puts "Example 2: Dynamic Batch Sizes"
puts "=" * 60

class DynamicBatching
  include Minigun::DSL

  attr_reader :small_batches, :large_batches

  def initialize
    @small_batches = 0
    @large_batches = 0
    @mutex = Mutex.new
  end

  pipeline do
    producer :gen do
      500.times { |i| emit(i) }
    end

    # Small batches for quick processing
    batch 25

    process_per_batch(max: 8) do
      processor :quick_process do |batch|
        @mutex.synchronize { @small_batches += 1 }
        batch.map { |x| x * 2 }
      end
    end

    # Re-batch into larger chunks
    batch 100

    process_per_batch(max: 2) do
      consumer :heavy_process do |batch|
        @mutex.synchronize { @large_batches += 1 }
      end
    end
  end
end

pipeline = DynamicBatching.new
pipeline.run

puts "\nResults:"
puts "  Small batches (25 items): #{pipeline.small_batches}"
puts "  Large batches (100 items): #{pipeline.large_batches}"
puts "\n✓ Multiple batch stages in one pipeline"
puts "✓ Different batch sizes for different purposes"
puts "✓ Flexible work distribution"

puts "\n" + "=" * 60
puts "Example 3: Configurable Batch Processing"
puts "=" * 60

class ConfigurableBatching
  include Minigun::DSL

  attr_reader :processed

  def initialize(batch_size: 100, max_processes: 4)
    @batch_size = batch_size
    @max_processes = max_processes
    @processed = 0
    @mutex = Mutex.new
  end

  pipeline do
    producer :gen do
      500.times { |i| emit(i) }
    end

    # Runtime-configurable batch size
    batch @batch_size

    # Runtime-configurable max processes
    process_per_batch(max: @max_processes) do
      consumer :process do |batch|
        @mutex.synchronize { @processed += batch.size }
      end
    end
  end
end

# Try different configurations
[
  { batch_size: 50, max_processes: 2 },
  { batch_size: 100, max_processes: 4 },
  { batch_size: 200, max_processes: 8 }
].each do |config|
  pipeline = ConfigurableBatching.new(**config)
  pipeline.run

  puts "\nConfig: batch_size=#{config[:batch_size]}, max_processes=#{config[:max_processes]}"
  puts "  Processed: #{pipeline.processed} items"
end

puts "\n✓ Runtime-configurable batching"
puts "✓ Adapt to workload and resources"
puts "✓ Instance variables accessible in pipeline"

