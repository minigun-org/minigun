#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

# Example: COW Fork -> IPC Fork Routing
#
# Demonstrates routing from COW fork stage to IPC fork stage.
# Combines ephemeral COW forks with persistent IPC workers.
#
# Architecture:
# - Producer (inline) -> Stage1 (COW fork) -> Stage2 (IPC fork) -> Collector (inline)
# - Stage1: Ephemeral COW forks, COW-shared input, IPC output
# - Stage2: Persistent IPC workers, full serialization in/out
# - Different execution models in same pipeline

class CowToIpcForkExample
  include Minigun::DSL

  attr_reader :results

  def initialize
    @results = []
  end

  pipeline do
    # Producer generates data in master process
    producer :generate do |output|
      puts "[Producer] Generating 8 items in master process (PID #{Process.pid})"
      8.times do |i|
        output << { id: i + 1, value: i + 1 }
      end
    end

    # First stage: COW fork (ephemeral, one fork per item)
    cow_fork(2) do
      processor :cow_stage do |item, output|
        pid = Process.pid
        puts "[COW Stage:cow_fork] Processing #{item[:id]} in ephemeral fork PID #{pid}"

        # Item is COW-shared (no serialization overhead for input)
        sleep 0.03 # Simulate work

        # Output goes back to parent via IPC (serialized)
        output << item.merge(
          cow_pid: pid,
          cow_processed: true,
          value: item[:value] * 10
        )
      end
    end

    # Second stage: IPC fork (persistent workers)
    ipc_fork(2) do
      processor :ipc_stage do |item, output|
        pid = Process.pid
        puts "[IPC Stage:ipc_fork] Processing #{item[:id]} in persistent worker PID #{pid}"

        sleep 0.03 # Simulate work

        # Output goes back to parent via IPC (serialized)
        output << item.merge(
          ipc_pid: pid,
          ipc_processed: true,
          value: item[:value] + 5
        )
      end
    end

    # Collector runs in master process
    consumer :collect do |item|
      puts "[Consumer] Collecting #{item[:id]} (COW PID: #{item[:cow_pid]}, IPC PID: #{item[:ipc_pid]})"
      @results << item
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  puts "=" * 80
  puts "Example: COW Fork -> IPC Fork Routing"
  puts "=" * 80
  puts ""

  example = CowToIpcForkExample.new
  begin
    example.run

    puts "\n" + "=" * 80
    puts "Results:"
    puts "  Items processed: #{example.results.size}"
    puts "  Expected: 8"

    cow_pids = example.results.map { |r| r[:cow_pid] }.uniq.sort
    ipc_pids = example.results.map { |r| r[:ipc_pid] }.uniq.sort

    puts "  COW fork PIDs: #{cow_pids.join(', ')} (#{cow_pids.size} ephemeral)"
    puts "  IPC worker PIDs: #{ipc_pids.join(', ')} (#{ipc_pids.size} persistent)"

    success = example.results.size == 8 &&
              example.results.all? { |r| r[:cow_processed] && r[:ipc_processed] }

    puts "  Status: #{success ? '✓ SUCCESS' : '✗ FAILED'}"
    puts "=" * 80
    puts ""
    puts "Key Points:"
    puts "  - COW stage: Ephemeral forks (one per item, exits after)"
    puts "  - IPC stage: Persistent workers (handle multiple items)"
    puts "  - Serialization boundaries:"
    puts "    1. Parent -> COW forks (COW-shared, no serialization)"
    puts "    2. COW forks -> Parent (IPC serialization)"
    puts "    3. Parent -> IPC workers (full serialization)"
    puts "    4. IPC workers -> Parent (full serialization)"
    puts "  - COW useful for: heavy computation with large inputs"
    puts "  - IPC useful for: persistent connections, resource pooling"
    puts "=" * 80
  rescue NotImplementedError => e
    puts "\nForking not available on this platform: #{e.message}"
    puts "(This is expected on Windows)"
  end
end
