#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

# Example: Thread -> IPC Fork -> Thread (Pass-through with IPC Result Sending)
#
# Demonstrates IPC fork as a middle stage (NOT terminal consumer).
# Since there's a downstream stage, results MUST be serialized back via IPC.
#
# Architecture:
# - Producer (inline) -> Processor (threads) -> Heavy Work (IPC fork) -> Collector (threads)
# - IPC fork stage MUST send results back to parent via IPC pipes
# - Parent routes results to downstream thread stage
# - Serialization happens twice: in -> IPC worker, out -> parent

class ThreadIpcThreadPassthroughExample
  include Minigun::DSL

  attr_reader :results

  def initialize
    @results = []
    @mutex = Mutex.new
  end

  pipeline do
    # Producer generates data in master process
    producer :generate do |output|
      puts "[Producer] Generating 8 items in master process (PID #{Process.pid})"
      8.times do |i|
        output << { id: i + 1, value: (i + 1) * 10 }
      end
    end

    # Light processor runs in thread pool
    thread_pool(2) do
      processor :enrich do |item, output|
        puts "[Processor:thread_pool] Enriching #{item[:id]} in thread #{Thread.current.object_id}"
        enriched = item.merge(enriched_at: Time.now.to_i)
        output << enriched
      end
    end

    # Heavy processor runs in IPC fork pool (middle stage - NOT terminal)
    # Results MUST be sent back to parent via IPC
    ipc_fork(2) do
      processor :heavy_compute do |item, output|
        pid = Process.pid
        puts "[Processor:ipc_fork] Heavy computation for #{item[:id]} in PID #{pid}"

        # Simulate heavy computation
        sleep 0.05

        # IMPORTANT: This output goes back to parent via IPC pipe (serialized)
        computed = item.merge(
          computed_value: item[:value]**2,
          worker_pid: pid
        )
        output << computed
      end
    end

    # Final collector runs in thread pool
    # Receives results from IPC fork via parent's routing
    thread_pool(2) do
      consumer :collect do |item|
        puts "[Consumer:thread_pool] Collecting #{item[:id]} from PID #{item[:worker_pid]}"
        @mutex.synchronize do
          @results << item
        end
      end
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  puts '=' * 80
  puts 'Example: Thread -> IPC Fork -> Thread (Pass-through)'
  puts '=' * 80
  puts ''

  example = ThreadIpcThreadPassthroughExample.new
  begin
    example.run

    puts "\n#{'=' * 80}"
    puts 'Results:'
    puts "  Items processed: #{example.results.size}"
    puts '  Expected: 8'

    worker_pids = example.results.map { |r| r[:worker_pid] }.uniq.sort
    puts "  Worker PIDs used: #{worker_pids.join(', ')}"
    puts "  Number of workers: #{worker_pids.size} (max: 2)"

    success = example.results.size == 8 &&
              example.results.map { |r| r[:id] }.sort == (1..8).to_a

    puts "  Status: #{success ? '✓ SUCCESS' : '✗ FAILED'}"
    puts '=' * 80
    puts ''
    puts 'Key Points:'
    puts '  - IPC fork is a MIDDLE stage (not terminal)'
    puts '  - Results must be serialized back to parent via IPC pipes'
    puts '  - Parent receives results and routes to downstream threads'
    puts '  - Two serialization boundaries:'
    puts '    1. Parent -> IPC worker (item in)'
    puts '    2. IPC worker -> Parent (result out)'
    puts '  - This is more expensive than terminal IPC consumer'
    puts '=' * 80
  rescue NotImplementedError => e
    puts "\nForking not available on this platform: #{e.message}"
    puts '(This is expected on Windows)'
  end
end
