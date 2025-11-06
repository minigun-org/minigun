#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

# Example: Mixed IPC/COW Fork Fan-In Pattern
#
# Demonstrates multiple stages using different fork types (IPC and COW)
# all routing to a single downstream aggregator.
# Shows heterogeneous cross-boundary routing with fan-in topology.
#
# Architecture:
# - [IPC Producer A, COW Producer B, IPC Producer C] -> Thread Aggregator
# - Different fork types feeding into single thread stage
# - Demonstrates mixing persistent (IPC) and ephemeral (COW) producers
class MixedIpcCowFanInExample
  include Minigun::DSL

  attr_reader :results

  def initialize
    @results = []
    @mutex = Mutex.new
  end

  pipeline do
    # Producer A in IPC fork (persistent worker)
    ipc_fork(1) do
      producer :producer_ipc_a do |output|
        pid = Process.pid
        puts "[ProducerIpcA:ipc_fork] Generating items in persistent worker PID #{pid}"
        4.times do |i|
          output << { id: "IPC_A#{i + 1}", value: i + 1, source: 'IPC_A', pid: pid }
        end
      end
    end

    # Producer B in COW fork (ephemeral forks)
    cow_fork(2) do
      producer :producer_cow_b do |output|
        pid = Process.pid
        puts "[ProducerCowB:cow_fork] Generating items in ephemeral fork PID #{pid}"
        4.times do |i|
          output << { id: "COW_B#{i + 1}", value: i + 1, source: 'COW_B', pid: pid }
        end
      end
    end

    # Producer C in IPC fork (persistent worker)
    ipc_fork(1) do
      producer :producer_ipc_c do |output|
        pid = Process.pid
        puts "[ProducerIpcC:ipc_fork] Generating items in persistent worker PID #{pid}"
        4.times do |i|
          output << { id: "IPC_C#{i + 1}", value: i + 1, source: 'IPC_C', pid: pid }
        end
      end
    end

    # Aggregator in thread pool - receives from all three producers
    thread_pool(2) do
      consumer :aggregator do |item|
        thread_id = Thread.current.object_id
        puts "[Aggregator:thread_pool] Processing #{item[:id]} from #{item[:source]} (producer PID #{item[:pid]}) in thread #{thread_id}"
        sleep 0.03

        @mutex.synchronize do
          @results << item.merge(thread_id: thread_id)
        end
      end
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  puts '=' * 80
  puts 'Example: Mixed IPC/COW Fork Fan-In Pattern'
  puts '=' * 80
  puts ''

  example = MixedIpcCowFanInExample.new
  begin
    example.run

    puts "\n#{'=' * 80}"
    puts 'Results:'
    puts "  Total items processed: #{example.results.size} (expected: 12)"

    by_source = example.results.group_by { |r| r[:source] }
    puts "  From ProducerIpcA: #{by_source['IPC_A']&.size || 0} items"
    puts "  From ProducerCowB: #{by_source['COW_B']&.size || 0} items"
    puts "  From ProducerIpcC: #{by_source['IPC_C']&.size || 0} items"

    ipc_a_pids = by_source['IPC_A']&.map { |r| r[:pid] }&.uniq || []
    cow_b_pids = by_source['COW_B']&.map { |r| r[:pid] }&.uniq || []
    ipc_c_pids = by_source['IPC_C']&.map { |r| r[:pid] }&.uniq || []

    puts "  IPC_A PIDs: #{ipc_a_pids.size} (persistent worker)"
    puts "  COW_B PIDs: #{cow_b_pids.size} (ephemeral, could be 1)"
    puts "  IPC_C PIDs: #{ipc_c_pids.size} (persistent worker)"

    success = example.results.size == 12 &&
              by_source['IPC_A']&.size == 4 &&
              by_source['COW_B']&.size == 4 &&
              by_source['IPC_C']&.size == 4

    puts "  Status: #{success ? '✓ SUCCESS' : '✗ FAILED'}"
    puts '=' * 80
    puts ''
    puts 'Key Points:'
    puts '  - Mixed fan-in: [IPC, COW, IPC] -> threads'
    puts '  - IPC producers: Persistent workers generate items'
    puts '  - COW producer: Ephemeral fork generates items'
    puts '  - All outputs merge at thread aggregator'
    puts '  - Serialization boundaries:'
    puts '    * IPC producers -> Parent (IPC serialization)'
    puts '    * COW producer -> Parent (IPC serialization)'
    puts '    * Parent -> Thread aggregator (shared memory)'
    puts '  - Demonstrates heterogeneous producer topologies'
    puts '=' * 80
  rescue NotImplementedError => e
    puts "\nForking not available on this platform: #{e.message}"
    puts '(This is expected on Windows)'
  end
end
