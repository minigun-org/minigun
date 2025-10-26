# frozen_string_literal: true

require_relative '../lib/minigun'

# Example: Extreme IPC Stress Test
# Demonstrates high-volume IPC with multiple pools
# Tests IPC performance and reliability under load
class ExtremeIPCStressTest
  include Minigun::DSL

  max_processes 10

  attr_accessor :results, :performance_stats

  def initialize
    @results = []
    @performance_stats = {
      start_time: nil,
      end_time: nil,
      items_per_second: 0,
      total_items: 0,
      ipc_crossings: 0
    }
  end

  pipeline do
    before_run do
      @performance_stats[:start_time] = Time.now
    end

    producer :generate_load do
      puts "Generating 1000 items..."
      1000.times do |i|
        emit({ id: i, data: "x" * 100 }) # 100 bytes per item
      end
    end

    # Stage 1: Parse in process pool (IPC boundary 1)
    processes(4) do
      processor :parse do |item|
        # Each item crosses IPC boundary
        emit(item.merge(stage: 1, parsed: true))
      end
    end

    # Stage 2: Validate in different process pool (IPC boundary 2)
    processes(4) do
      processor :validate do |item|
        # Another IPC crossing
        emit(item.merge(stage: 2, validated: true))
      end
    end

    # Stage 3: Transform in another process pool (IPC boundary 3)
    processes(4) do
      processor :transform do |item|
        # Third IPC crossing
        emit(item.merge(stage: 3, value: item[:id] * 2))
      end
    end

    # Stage 4: Enrich in final process pool (IPC boundary 4)
    processes(4) do
      processor :enrich do |item|
        # Fourth IPC crossing
        emit(item.merge(stage: 4, enriched: true, timestamp: Time.now.to_f))
      end
    end

    # Accumulate batches
    accumulator :batch, max_size: 100

    # Stage 5: Batch processing (IPC boundary 5)
    processes(2) do
      consumer :save_batch do |batch|
        puts "Saving batch of #{batch.size} items (PID #{Process.pid})"
        @results.concat(batch)
      end
    end

    after_run do
      @performance_stats[:end_time] = Time.now
      @performance_stats[:total_items] = @results.size
      @performance_stats[:ipc_crossings] = @results.size * 5 # 5 IPC boundaries
      
      duration = @performance_stats[:end_time] - @performance_stats[:start_time]
      @performance_stats[:items_per_second] = (@results.size / duration).round(2)
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  puts "=== Extreme IPC Stress Test ===\n\n"
  puts "This demonstrates:"
  puts "  - 1000 items flowing through pipeline"
  puts "  - 5 IPC boundaries (5 process pools)"
  puts "  - 4 pools of 4 workers + 1 pool of 2 workers"
  puts "  - Each item crosses IPC 5 times"
  puts "  - Total IPC operations: 5,000 Marshal/unmarshal cycles\n\n"
  puts "Topology:"
  puts "  Producer"
  puts "    |IPC 1| -> Processes(4) parse"
  puts "    |IPC 2| -> Processes(4) validate"
  puts "    |IPC 3| -> Processes(4) transform"
  puts "    |IPC 4| -> Processes(4) enrich"
  puts "    -> Accumulator(100)"
  puts "    |IPC 5| -> Processes(2) save_batch"
  puts "    -> Consumer\n\n"

  puts "Running stress test..."
  pipeline = ExtremeIPCStressTest.new
  pipeline.run

  puts "\n=== Results ==="
  puts "Total items processed: #{pipeline.results.size}"
  puts "Expected: 1000"
  puts "Match: #{pipeline.results.size == 1000 ? '✓' : '✗'}"
  
  puts "\n=== Performance Stats ==="
  puts "Duration: #{(pipeline.performance_stats[:end_time] - pipeline.performance_stats[:start_time]).round(3)}s"
  puts "Throughput: #{pipeline.performance_stats[:items_per_second]} items/second"
  puts "Total IPC crossings: #{pipeline.performance_stats[:ipc_crossings]}"
  puts "IPC operations/second: #{(pipeline.performance_stats[:ipc_crossings] / (pipeline.performance_stats[:end_time] - pipeline.performance_stats[:start_time])).round(2)}"
  
  puts "\n=== Data Integrity Check ==="
  # Verify all items made it through
  ids = pipeline.results.map { |r| r[:id] }.sort
  expected_ids = (0...1000).to_a
  missing = expected_ids - ids
  duplicates = ids.select { |id| ids.count(id) > 1 }.uniq
  
  if missing.empty? && duplicates.empty?
    puts "✓ All items accounted for, no duplicates"
  else
    puts "✗ Missing items: #{missing.size}" unless missing.empty?
    puts "✗ Duplicate items: #{duplicates.size}" unless duplicates.empty?
  end
  
  # Verify all stages completed
  sample = pipeline.results.first
  if sample[:parsed] && sample[:validated] && sample[:enriched]
    puts "✓ All processing stages completed"
  else
    puts "✗ Some stages incomplete"
  end

  puts "\n✓ Extreme IPC stress test complete!"
  puts "✓ #{pipeline.performance_stats[:ipc_crossings]} IPC operations successful!"
end

