#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

# Example: IPC Fork -> COW Fork Routing
#
# Demonstrates routing from IPC fork stage to COW fork stage.
# Combines persistent IPC workers with ephemeral COW forks.
#
# Architecture:
# - Producer (inline) -> Stage1 (IPC fork) -> Stage2 (COW fork) -> Collector (inline)
# - Stage1: Persistent IPC workers, full serialization in/out
# - Stage2: Ephemeral COW forks, COW-shared input, IPC output
# - Different execution models in same pipeline
class IpcToCowForkExample
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

    # First stage: IPC fork (persistent workers)
    ipc_fork(2) do
      processor :ipc_stage do |item, output|
        pid = Process.pid
        puts "[IPC Stage:ipc_fork] Processing #{item[:id]} in persistent worker PID #{pid}"

        sleep 0.03 # Simulate work

        # Output goes back to parent via IPC (serialized)
        output << item.merge(
          ipc_pid: pid,
          ipc_processed: true,
          value: item[:value] * 10
        )
      end
    end

    # Second stage: COW fork (ephemeral, one fork per item)
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
          value: item[:value] + 5
        )
      end
    end

    # Collector runs in master process
    consumer :collect do |item|
      puts "[Consumer] Collecting #{item[:id]} (IPC PID: #{item[:ipc_pid]}, COW PID: #{item[:cow_pid]})"
      @results << item
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  puts '=' * 80
  puts 'Example: IPC Fork -> COW Fork Routing'
  puts '=' * 80
  puts ''

  example = IpcToCowForkExample.new
  begin
    example.run

    puts "\n#{'=' * 80}"
    puts 'Results:'
    puts "  Items processed: #{example.results.size}"
    puts '  Expected: 8'

    ipc_pids = example.results.map { |r| r[:ipc_pid] }.uniq.sort
    cow_pids = example.results.map { |r| r[:cow_pid] }.uniq.sort

    puts "  IPC worker PIDs: #{ipc_pids.join(', ')} (#{ipc_pids.size} persistent)"
    puts "  COW fork PIDs: #{cow_pids.join(', ')} (#{cow_pids.size} ephemeral)"

    success = example.results.size == 8 &&
              example.results.all? { |r| r[:ipc_processed] && r[:cow_processed] }

    puts "  Status: #{success ? '✓ SUCCESS' : '✗ FAILED'}"
    puts '=' * 80
    puts ''
    puts 'Key Points:'
    puts '  - IPC stage: Persistent workers (handle multiple items)'
    puts '  - COW stage: Ephemeral forks (one per item)'
    puts '  - Different process lifecycle models'
    puts '  - Serialization boundaries:'
    puts '    1. Parent -> IPC workers (full serialization)'
    puts '    2. IPC workers -> Parent (full serialization)'
    puts '    3. Parent -> COW forks (COW-shared, no serialization)'
    puts '    4. COW forks -> Parent (IPC serialization)'
    puts '  - COW forks may create many more PIDs than IPC workers'
    puts '=' * 80
  rescue NotImplementedError => e
    puts "\nForking not available on this platform: #{e.message}"
    puts '(This is expected on Windows)'
  end
end
