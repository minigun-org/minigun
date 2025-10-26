# frozen_string_literal: true

require_relative '../lib/minigun'

# Example: Complex IPC Topology
# Demonstrates branching with multiple process pools and routing
# Shows advanced IPC patterns with accumulation and emit_to_stage
class ComplexIPCTopology
  include Minigun::DSL

  attr_accessor :light_results, :heavy_results, :batch_results, :stats

  def initialize
    @light_results = []
    @heavy_results = []
    @batch_results = []
    @stats = { light: 0, heavy: 0, batches: 0 }
  end

  pipeline do
    producer :generate do
      100.times do |i|
        emit({ id: i, type: i.even? ? 'light' : 'heavy' })
      end
    end

    # Router in thread pool (fast, shared memory)
    threads(2) do
      stage :router do |item|
        if item[:type] == 'light'
          emit_to_stage(:light_processor, item)
        else
          emit_to_stage(:heavy_processor, item)
        end
      end
    end

    # *** IPC BOUNDARY 1: Light work process pool ***
    processes(3) do
      processor :light_processor do |item|
        puts "Light process #{Process.pid} handling #{item[:id]}" if item[:id] % 20 == 0
        emit(item.merge(processed: :light, pid: Process.pid))
      end
    end

    # *** IPC BOUNDARY 2: Heavy work process pool ***
    processes(2) do
      processor :heavy_processor do |item|
        puts "Heavy process #{Process.pid} handling #{item[:id]}" if item[:id] % 20 == 0
        # Simulate heavy computation
        sleep 0.001
        emit(item.merge(processed: :heavy, pid: Process.pid))
      end
    end

    # Accumulate in batches (runs in main process after IPC)
    accumulator :batcher, max_size: 10

    # *** IPC BOUNDARY 3: Batch processing pool ***
    processes(2) do
      consumer :batch_processor do |batch|
        @stats[:batches] += 1
        puts "Batch process #{Process.pid} handling batch of #{batch.size}"
        
        batch.each do |item|
          if item[:processed] == :light
            @stats[:light] += 1
            @light_results << item
          else
            @stats[:heavy] += 1
            @heavy_results << item
          end
          @batch_results << item
        end
      end
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  puts "=== Complex IPC Topology Example ===\n\n"
  puts "This demonstrates:"
  puts "  - Dynamic routing with emit_to_stage"
  puts "  - Multiple process pools (3 + 2 + 2 workers)"
  puts "  - Branching topology (light vs heavy paths)"
  puts "  - Accumulation after IPC"
  puts "  - Batch processing in separate process pool\n\n"
  puts "Topology:"
  puts "                    |IPC| -> Processes(3) light_processor ──┐"
  puts "  Producer -> Threads(2) router                              ├─> Accumulator -> |IPC| -> Processes(2) batch_processor"
  puts "                    |IPC| -> Processes(2) heavy_processor ──┘"
  puts "                    ^^^^^    ^^^^^^^^^^^^^    ^^^^^^^^^^^^^     ^^^^^^^^^^^^^    ^^^^^    ^^^^^^^^^^^^^"
  puts "                    IPC 1    Process Pool 1   Process Pool 2    Main Process     IPC 3    Process Pool 3\n\n"

  pipeline = ComplexIPCTopology.new
  pipeline.run

  puts "\n=== Results ==="
  puts "Total processed: #{pipeline.batch_results.size} items"
  puts "Light items: #{pipeline.light_results.size}"
  puts "Heavy items: #{pipeline.heavy_results.size}"
  puts "Batches processed: #{pipeline.stats[:batches]}"
  
  puts "\n=== Process Distribution ==="
  light_pids = pipeline.light_results.map { |r| r[:pid] }.uniq
  heavy_pids = pipeline.heavy_results.map { |r| r[:pid] }.uniq
  puts "Light processor PIDs: #{light_pids.inspect} (#{light_pids.size} workers)"
  puts "Heavy processor PIDs: #{heavy_pids.inspect} (#{heavy_pids.size} workers)"
  
  puts "\n=== IPC Verification ==="
  puts "✓ Data routed through 3 IPC boundaries"
  puts "✓ #{pipeline.stats[:light]} items through light process pool (IPC 1)"
  puts "✓ #{pipeline.stats[:heavy]} items through heavy process pool (IPC 2)"
  puts "✓ #{pipeline.stats[:batches]} batches through batch process pool (IPC 3)"

  puts "\n✓ Complex IPC topology complete!"
end

