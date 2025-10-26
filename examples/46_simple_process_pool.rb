# frozen_string_literal: true

require_relative '../lib/minigun'
require 'tempfile'

# Example: Simple Process Pool IPC
# Demonstrates a basic producer -> process pool -> consumer pipeline
# with data flowing through IPC (Marshal over pipes)
class SimpleProcessPool
  include Minigun::DSL

  attr_accessor :results, :process_info

  def initialize
    @results = []
    @process_info = { producer_pid: nil, worker_pids: [], consumer_pid: nil }
  end

  pipeline do
    # Producer runs in main process
    producer :generate_data do
      @process_info[:producer_pid] = Process.pid
      puts "Producer PID: #{Process.pid}"
      
      100.times do |i|
        emit(i)
      end
    end

    # Process pool of 4 workers - each item goes through IPC
    processes(4) do
      processor :cpu_heavy_work do |num|
        # Track worker PIDs
        pid = Process.pid
        puts "Worker PID #{pid} processing #{num}" if num % 20 == 0
        
        # Simulate CPU-heavy work
        result = num * num
        emit(result)
      end
    end

    # Consumer runs in main process
    consumer :collect do |result|
      @process_info[:consumer_pid] = Process.pid
      @results << result
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  puts "=== Simple Process Pool IPC Example ===\n\n"
  puts "This demonstrates:"
  puts "  - Producer in main process"
  puts "  - Process pool of 4 workers (persistent, reused)"
  puts "  - Data flows via IPC (Marshal over pipes)"
  puts "  - Consumer in main process\n\n"

  pipeline = SimpleProcessPool.new
  pipeline.run

  puts "\n=== Results ==="
  puts "Processed: #{pipeline.results.size} items"
  puts "First 10 results: #{pipeline.results.take(10).inspect}"
  puts "Last 10 results: #{pipeline.results.last(10).inspect}"
  
  puts "\n=== Process Info ==="
  puts "Producer PID: #{pipeline.process_info[:producer_pid]}"
  puts "Consumer PID: #{pipeline.process_info[:consumer_pid]}"
  puts "Same as main? #{pipeline.process_info[:producer_pid] == Process.pid}"

  puts "\n✓ Simple process pool IPC complete!"
end

