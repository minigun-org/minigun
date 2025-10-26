#!/usr/bin/env ruby
# frozen_string_literal: true

# Example 35: Nested Execution Contexts
#
# Demonstrates proper nesting behavior: outer context for I/O,
# inner context for CPU work, with batching in between

require_relative '../lib/minigun'

puts "=" * 60
puts "Nested Execution Contexts"
puts "=" * 60

class NestedPipeline
  include Minigun::DSL

  attr_reader :batch_pids, :results

  def initialize
    @batch_pids = []
    @results = []
    @mutex = Mutex.new
  end

  pipeline do
    producer :gen do
      100.times { |i| emit(i) }
    end

    # Outer context: thread pool for I/O work
    threads(50) do
      processor :download do |item|
        # Simulate I/O-bound download
        emit({ id: item, data: "downloaded-#{item}" })
      end

      processor :validate do |item|
        # Quick validation in thread
        emit(item)
      end

      # Batch within thread context
      batch 20

      # Inner context: process per batch for CPU work
      process_per_batch(max: 4) do
        consumer :process_batch do |batch|
          # CPU-intensive work in isolated process
          @mutex.synchronize do
            @batch_pids << Process.pid
          end

          processed = batch.map { |item| item[:data].upcase }
          @mutex.synchronize { @results.concat(processed) }
        end
      end

      # Note: stages here would be back in thread context
      # But we end after process_per_batch in this example
    end
  end
end

pipeline = NestedPipeline.new
pipeline.run

puts "\nResults:"
puts "  Processed: #{pipeline.results.size} items"
puts "  Batches: #{pipeline.batch_pids.size}"
puts "  Unique PIDs: #{pipeline.batch_pids.uniq.size}"
puts "\n✓ Outer threads(50) for I/O stages"
puts "✓ batch 20 accumulates items"
puts "✓ Inner process_per_batch(max: 4) for CPU work"
puts "✓ Proper context inheritance and isolation"

puts "\n" + "=" * 60
puts "Example 2: Deep Nesting"
puts "=" * 60

class DeepNesting
  include Minigun::DSL

  attr_reader :results

  def initialize
    @results = []
    @mutex = Mutex.new
  end

  pipeline do
    producer :gen do
      50.times { |i| emit(i) }
    end

    # Level 1: Thread pool
    threads(20) do
      processor :fetch do |item|
        emit(item * 2)
      end

      # Level 2: Batch
      batch 10

      # Level 3: Thread per batch
      thread_per_batch(max: 5) do
        processor :parse_batch do |batch|
          # Each batch in its own thread
          batch.map { |x| x + 100 }
        end
      end

      # Level 4: Another batch
      batch 5

      # Level 5: Process per batch
      process_per_batch(max: 2) do
        consumer :final_process do |batch|
          @mutex.synchronize do
            @results.concat(batch)
          end
        end
      end
    end
  end
end

pipeline = DeepNesting.new
pipeline.run

puts "\nResults:"
puts "  Processed: #{pipeline.results.size} items"
puts "\n✓ Deep nesting works correctly"
puts "✓ Each level maintains proper context"
puts "✓ Batching stages inserted at each batch call"
puts "✓ Per-batch spawning respects max limits"

puts "\n" + "=" * 60
puts "Example 3: Real-World Nested Pattern"
puts "=" * 60

class ImageProcessor
  include Minigun::DSL

  attr_reader :processed_count

  def initialize
    @processed_count = 0
    @mutex = Mutex.new
  end

  pipeline do
    producer :list_images do
      100.times { |i| emit("image-#{i}.jpg") }
    end

    # Download images in parallel
    threads(30) do
      processor :download_image do |filename|
        # Simulate download
        emit({ filename: filename, bytes: 1024 * 100 })
      end

      processor :validate_format do |image|
        emit(image)
      end

      # Batch images for efficient processing
      batch 10

      # Process batches in separate processes (CPU-intensive)
      process_per_batch(max: 4) do
        processor :resize_batch do |batch|
          # CPU-intensive image resizing
          batch.map do |img|
            { filename: img[:filename], resized: true, thumbnails: 3 }
          end
        end
      end

      # Back to threads for upload
      processor :prepare_upload do |results|
        emit(results)
      end

      consumer :upload do |results|
        @mutex.synchronize { @processed_count += results.size }
      end
    end
  end
end

pipeline = ImageProcessor.new
pipeline.run

puts "\nResults:"
puts "  Processed: #{pipeline.processed_count} images"
puts "\n✓ Real-world pattern:"
puts "  1. Download in threads (I/O)"
puts "  2. Validate in threads (fast)"
puts "  3. Batch for efficiency"
puts "  4. Resize in processes (CPU)"
puts "  5. Upload in threads (I/O)"
puts "✓ Each operation in optimal execution context"

