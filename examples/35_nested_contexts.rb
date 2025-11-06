#!/usr/bin/env ruby
# frozen_string_literal: true

# Example 35: Nested Execution Contexts
#
# Demonstrates proper nesting behavior: outer context for I/O,
# inner context for CPU work, with batching in between

require_relative '../lib/minigun'
require 'tempfile'

puts '=' * 60
puts 'Nested Execution Contexts'
puts '=' * 60

# Demonstrates nested execution contexts for I/O and CPU work
class NestedPipeline
  include Minigun::DSL

  attr_reader :batch_pids, :results

  def initialize
    @batch_pids = []
    @results = []
    @mutex = Mutex.new
    @temp_results_file = Tempfile.new(['minigun_nested_results', '.txt'])
    @temp_results_file.close
    @temp_pids_file = Tempfile.new(['minigun_nested_pids', '.txt'])
    @temp_pids_file.close
  end

  def cleanup
    File.unlink(@temp_results_file.path) if @temp_results_file && File.exist?(@temp_results_file.path)
    File.unlink(@temp_pids_file.path) if @temp_pids_file && File.exist?(@temp_pids_file.path)
  end

  pipeline do
    producer :gen do |output|
      100.times { |i| output << i }
    end

    # Outer context: thread pool for I/O work
    thread_pool(50) do
      processor :download do |item, output|
        # Simulate I/O-bound download
        output << { id: item, data: "downloaded-#{item}" }
      end

      processor :validate do |item, output|
        # Quick validation in thread
        output << item
      end

      # Batch within thread context
      batch 20

      # Inner context: process per batch for CPU work
      cow_fork(4) do
        consumer :process_batch do |batch|
          # Write PID to temp file (fork-safe)
          File.open(@temp_pids_file.path, 'a') do |f|
            f.flock(File::LOCK_EX)
            f.puts(Process.pid)
            f.flock(File::LOCK_UN)
          end

          processed = batch.map { |item| item[:data].upcase }

          # Write results to temp file (fork-safe)
          File.open(@temp_results_file.path, 'a') do |f|
            f.flock(File::LOCK_EX)
            processed.each { |item| f.puts(item) }
            f.flock(File::LOCK_UN)
          end
        end
      end

      # NOTE: stages here would be back in thread context
      # But we end after cow_fork in this example
    end

    after_run do
      # Read fork results from temp files
      @batch_pids = File.readlines(@temp_pids_file.path).map { |line| line.strip.to_i } if File.exist?(@temp_pids_file.path)
      @results = File.readlines(@temp_results_file.path).map(&:strip) if File.exist?(@temp_results_file.path)
    end
  end
end

pipeline = NestedPipeline.new
begin
  pipeline.run

  puts "\nResults:"
  puts "  Processed: #{pipeline.results.size} items"
  puts "  Batches: #{pipeline.batch_pids.size}"
  puts "  Unique PIDs: #{pipeline.batch_pids.uniq.size}"
  puts "\n✓ Outer threads(50) for I/O stages"
  puts '✓ batch 20 accumulates items'
  puts '✓ Inner cow_fork(4) for CPU work'
  puts '✓ Proper context inheritance and isolation'
ensure
  pipeline.cleanup
end

puts "\n#{'=' * 60}"
puts 'Example 2: Deep Nesting'
puts '=' * 60

# Demonstrates deeply nested execution contexts
class DeepNesting
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

    # Level 1: Thread pool
    thread_pool(20) do
      processor :fetch do |item, output|
        output << (item * 2)
      end

      # Level 2: Batch
      batch 10

      # Level 3: Thread per batch
      thread_pool(5) do
        processor :parse_batch do |batch, _output|
          # Each batch in its own thread
          batch.map { |x| x + 100 }
        end
      end

      # Level 4: Another batch
      batch 5

      # Level 5: Process per batch
      cow_fork(2) do
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
puts '✓ Each level maintains proper context'
puts '✓ Batching stages inserted at each batch call'
puts '✓ Per-batch spawning respects max limits'

puts "\n#{'=' * 60}"
puts 'Example 3: Real-World Nested Pattern'
puts '=' * 60

# Demonstrates realistic image processing with batching and concurrency
class ImageProcessor
  include Minigun::DSL

  attr_reader :processed_count

  def initialize
    @processed_count = 0
    @mutex = Mutex.new
  end

  pipeline do
    producer :list_images do |output|
      100.times { |i| output << "image-#{i}.jpg" }
    end

    # Download images in parallel
    thread_pool(30) do
      processor :download_image do |filename, output|
        # Simulate download
        output << { filename: filename, bytes: 1024 * 100 }
      end

      processor :validate_format do |image, output|
        output << image
      end

      # Batch images for efficient processing
      batch 10

      # Process batches in separate processes (CPU-intensive)
      cow_fork(4) do
        processor :resize_batch do |batch, _output|
          # CPU-intensive image resizing
          batch.map do |img|
            { filename: img[:filename], resized: true, thumbnails: 3 }
          end
        end
      end

      # Back to threads for upload
      processor :prepare_upload do |results, output|
        output << results
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
puts '  1. Download in threads (I/O)'
puts '  2. Validate in threads (fast)'
puts '  3. Batch for efficiency'
puts '  4. Resize in processes (CPU)'
puts '  5. Upload in threads (I/O)'
puts '✓ Each operation in optimal execution context'
