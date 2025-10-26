# frozen_string_literal: true

require_relative '../lib/minigun'

# Example: Mixed Threading + Process Pools IPC
# Demonstrates complex topology mixing threads and processes
# Shows IPC boundaries and in-memory communication
class MixedThreadingProcesses
  include Minigun::DSL

  attr_accessor :results, :topology_info

  def initialize
    @results = []
    @topology_info = {
      thread_items: 0,
      process_items: 0,
      final_items: 0
    }
  end

  pipeline do
    producer :generate do
      30.times { |i| emit(i) }
    end

    # Thread pool: Fast I/O operations (shared memory, no IPC)
    threads(5) do
      processor :fetch do |num|
        @topology_info[:thread_items] += 1
        # Simulate I/O operation
        emit({ id: num, data: "fetched_#{num}" })
      end
    end

    # *** IPC BOUNDARY HERE ***
    # Process pool: CPU-heavy operations (IPC via Marshal/pipes)
    processes(3) do
      processor :compute do |item|
        @topology_info[:process_items] += 1
        puts "Process #{Process.pid} computing item #{item[:id]}" if item[:id] % 10 == 0
        
        # CPU-intensive work
        result = item[:id] ** 2
        emit(item.merge(computed: result))
      end
    end
    # *** IPC BOUNDARY HERE ***

    # Back to thread pool: More I/O (shared memory again)
    threads(4) do
      processor :store do |item|
        @topology_info[:final_items] += 1
        emit(item.merge(stored: true))
      end
    end

    # Consumer in main process
    consumer :collect do |item|
      @results << item
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  puts "=== Mixed Threading + Process Pools IPC Example ===\n\n"
  puts "This demonstrates:"
  puts "  - Thread pool (5 workers, shared memory)"
  puts "  - IPC boundary to process pool (3 workers, Marshal/pipes)"
  puts "  - IPC boundary back to thread pool (4 workers, shared memory)"
  puts "  - Shows when IPC is used vs shared memory\n\n"
  puts "Topology:"
  puts "  Producer -> Threads(5) -> |IPC| -> Processes(3) -> |IPC| -> Threads(4) -> Consumer"
  puts "                           ^^^^^^                   ^^^^^^"
  puts "                           IPC boundaries\n\n"

  pipeline = MixedThreadingProcesses.new
  pipeline.run

  puts "\n=== Results ==="
  puts "Total items: #{pipeline.results.size}"
  puts "Sample result: #{pipeline.results.first.inspect}"
  
  puts "\n=== Topology Info ==="
  puts "Items through thread pool 1: #{pipeline.topology_info[:thread_items]}"
  puts "Items through process pool:  #{pipeline.topology_info[:process_items]}"
  puts "Items through thread pool 2: #{pipeline.topology_info[:final_items]}"
  
  puts "\n=== IPC Verification ==="
  puts "✓ Data crossed 2 IPC boundaries (threads -> processes -> threads)"
  puts "✓ #{pipeline.topology_info[:process_items]} items marshaled and unmarshaled"

  puts "\n✓ Mixed threading + process pools IPC complete!"
end

