#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

# Example: IPC Fork -> IPC Fork Routing
#
# Demonstrates routing between two IPC fork stages.
# Both stages use persistent IPC workers with full serialization.
#
# Architecture:
# - Producer (inline) -> Stage1 (IPC fork) -> Stage2 (IPC fork) -> Collector (inline)
# - Stage1 IPC workers receive items via IPC, send results back via IPC
# - Parent routes Stage1 results to Stage2 input Queue
# - Stage2 IPC workers receive items via IPC, send results back via IPC
# - Full serialization at every boundary
class IpcToIpcForkExample
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

    # First IPC fork stage
    ipc_fork(2) do
      processor :stage1 do |item, output|
        pid = Process.pid
        puts "[Stage1:ipc_fork] Processing #{item[:id]} in PID #{pid}"

        sleep 0.03 # Simulate work

        # Output goes back to parent via IPC (serialized)
        output << item.merge(
          stage1_pid: pid,
          stage1_processed: true,
          value: item[:value] * 10
        )
      end
    end

    # Second IPC fork stage
    # Receives items from parent (via Queue) after Stage1
    ipc_fork(2) do
      processor :stage2 do |item, output|
        pid = Process.pid
        puts "[Stage2:ipc_fork] Processing #{item[:id]} in PID #{pid}"

        sleep 0.03 # Simulate work

        # Output goes back to parent via IPC (serialized)
        output << item.merge(
          stage2_pid: pid,
          stage2_processed: true,
          value: item[:value] + 5
        )
      end
    end

    # Collector runs in master process
    consumer :collect do |item|
      puts "[Consumer] Collecting #{item[:id]} (Stage1 PID: #{item[:stage1_pid]}, Stage2 PID: #{item[:stage2_pid]})"
      @results << item
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  puts '=' * 80
  puts 'Example: IPC Fork -> IPC Fork Routing'
  puts '=' * 80
  puts ''

  example = IpcToIpcForkExample.new
  begin
    example.run

    puts "\n#{'=' * 80}"
    puts 'Results:'
    puts "  Items processed: #{example.results.size}"
    puts '  Expected: 8'

    stage1_pids = example.results.map { |r| r[:stage1_pid] }.uniq.sort
    stage2_pids = example.results.map { |r| r[:stage2_pid] }.uniq.sort

    puts "  Stage1 PIDs: #{stage1_pids.join(', ')} (#{stage1_pids.size} workers)"
    puts "  Stage2 PIDs: #{stage2_pids.join(', ')} (#{stage2_pids.size} workers)"

    success = example.results.size == 8 &&
              example.results.all? { |r| r[:stage1_processed] && r[:stage2_processed] }

    puts "  Status: #{success ? '✓ SUCCESS' : '✗ FAILED'}"
    puts '=' * 80
    puts ''
    puts 'Key Points:'
    puts '  - Two sequential IPC fork stages'
    puts '  - Four serialization boundaries:'
    puts '    1. Parent -> Stage1 workers (item in)'
    puts '    2. Stage1 workers -> Parent (result out)'
    puts '    3. Parent -> Stage2 workers (item in)'
    puts '    4. Stage2 workers -> Parent (result out)'
    puts '  - Parent orchestrates routing between stages via Queues'
    puts '  - IPC workers are persistent (handle multiple items)'
    puts '  - Strong process isolation at each stage'
    puts '=' * 80
  rescue NotImplementedError => e
    puts "\nForking not available on this platform: #{e.message}"
    puts '(This is expected on Windows)'
  end
end
