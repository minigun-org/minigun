#!/usr/bin/env ruby
# frozen_string_literal: true

# Example 38: Complete Refactor 2 Demo
#
# Comprehensive example showing all Refactor 2 features working together

require_relative '../lib/minigun'

puts '=' * 60
puts 'Complete Refactor 2 Feature Demonstration'
puts '=' * 60

class ComprehensivePipeline
  include Minigun::DSL

  attr_reader :stats

  def initialize(
    download_threads: 50,
    parse_processes: 4,
    batch_size: 100,
    upload_threads: 20
  )
    @download_threads = download_threads
    @parse_processes = parse_processes
    @batch_size = batch_size
    @upload_threads = upload_threads

    @stats = {
      downloaded: 0,
      parsed: 0,
      uploaded: 0,
      parse_pids: []
    }
    @mutex = Mutex.new
  end

  pipeline do
    # Define named contexts for specific use
    execution_context :db_pool, :threads, 5
    execution_context :cache_pool, :threads, 10

    # Generate work items
    producer :generate_urls do |output|
      200.times { |i| output << { id: i, url: "https://api.example.com/item-#{i}" } }
    end

    # Check cache first (small dedicated pool)
    processor :check_cache, execution_context: :cache_pool do |item, output|
      # Simulate cache lookup
      item[:cached] = false
      output << item
    end

    # Download phase: I/O-bound, use thread pool
    threads(@download_threads) do
      processor :download do |item, output|
        @mutex.synchronize { @stats[:downloaded] += 1 }

        # Simulate HTTP request
        item[:data] = "response-#{item[:id]}"
        output << item
      end

      processor :extract_metadata do |item, output|
        item[:metadata] = { size: 1024, type: 'json' }
        output << item
      end
    end

    # Batch for efficient processing
    batch @batch_size

    # Parse phase: CPU-bound, use process per batch
    process_per_batch(max: @parse_processes) do
      processor :parse_batch do |batch, output|
        # NOTE: Stats incremented in parent process would not be visible here
        # since this runs in a forked process

        # CPU-intensive parsing
        batch.each do |item|
          output << {
            id: item[:id],
            parsed: item[:data].upcase,
            metadata: item[:metadata],
            parse_pid: Process.pid # Track which process did the work
          }
        end
      end
    end

    # Save to database (dedicated small pool)
    # Stats are incremented here (in parent process) so they're visible
    processor :save_to_db, execution_context: :db_pool do |results, output|
      @mutex.synchronize do
        @stats[:parsed] += 1
        @stats[:parse_pids] << results[:parse_pid] if results[:parse_pid]
      end
      # Simulate database write
      output << results
    end

    # Upload phase: I/O-bound, use thread pool
    threads(@upload_threads) do
      consumer :upload_to_s3 do |results|
        @mutex.synchronize { @stats[:uploaded] += results.size }
      end
    end
  end
end

# Run with default configuration
puts 'Running with default configuration...'
pipeline = ComprehensivePipeline.new
pipeline.run

puts "\nResults:"
puts "  Downloaded: #{pipeline.stats[:downloaded]} items"
puts "  Parsed: #{pipeline.stats[:parsed]} items"
puts "  Uploaded: #{pipeline.stats[:uploaded]} items"
puts "  Parse PIDs: #{pipeline.stats[:parse_pids].uniq.size} unique processes"

puts "\n✓ Named contexts (db_pool, cache_pool)"
puts '✓ Thread pools (download_threads, upload_threads)'
puts '✓ Process per batch (parse_processes)'
puts '✓ Runtime configuration via instance variables'
puts '✓ Batching for efficiency'
puts '✓ All features working together seamlessly'

puts "\n#{'=' * 60}"
puts 'Running with high-concurrency configuration...'
puts '=' * 60

high_concurrency = ComprehensivePipeline.new(
  download_threads: 100,
  parse_processes: 8,
  batch_size: 50,
  upload_threads: 50
)
high_concurrency.run

puts "\nResults (high concurrency):"
puts "  Downloaded: #{high_concurrency.stats[:downloaded]} items"
puts "  Parsed: #{high_concurrency.stats[:parsed]} items"
puts "  Uploaded: #{high_concurrency.stats[:uploaded]} items"

puts "\n✓ Same pipeline, different configuration"
puts '✓ Adapt to available resources'
puts '✓ Clean, declarative syntax'

puts "\n#{'=' * 60}"
puts 'Summary of Refactor 2 Features'
puts '=' * 60
puts <<~SUMMARY

  ✓ Execution Blocks:
    - threads(N) do ... end
    - processes(N) do ... end
    - ractors(N) do ... end

  ✓ Per-Batch Spawning:
    - thread_per_batch(max: N) do ... end
    - process_per_batch(max: N) do ... end
    - ractor_per_batch(max: N) do ... end

  ✓ Batching:
    - batch N (creates accumulator stage)
    - Multiple batch stages per pipeline
    - Runtime-configurable sizes

  ✓ Named Contexts:
    - execution_context :name, :type, size
    - processor :stage, execution_context: :name
    - Reusable, declarative

  ✓ Nesting:
    - Natural context inheritance
    - Inner contexts override outer
    - Batching works within any context

  ✓ Configuration:
    - Instance variables (@threads, @batch_size)
    - Runtime-configurable
    - Environment-aware

  Benefits:
  ✓ Clear intent (what work, what context)
  ✓ No strategy: options needed
  ✓ Composable and reusable
  ✓ Type-safe context management
  ✓ Optimal resource utilization
SUMMARY
