#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

# Example: COW Fork -> COW Fork Routing
#
# Demonstrates routing between two COW fork stages.
# Both stages use ephemeral forks with COW-shared inputs.
#
# Architecture:
# - Producer (inline) -> Stage1 (COW fork) -> Stage2 (COW fork) -> Collector (inline)
# - Stage1: COW-shared input, IPC output to parent
# - Stage2: COW-shared input (from parent), IPC output to parent
# - Multiple ephemeral forks at each stage
class CowToCowForkExample
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

    # First COW fork stage
    cow_fork(2) do
      processor :stage1 do |item, output|
        pid = Process.pid
        puts "[Stage1:cow_fork] Processing #{item[:id]} in ephemeral fork PID #{pid}"

        # Item is COW-shared (no serialization overhead for input)
        sleep 0.03 # Simulate work

        # Output goes back to parent via IPC (serialized)
        output << item.merge(
          stage1_pid: pid,
          stage1_processed: true,
          value: item[:value] * 10
        )
      end
    end

    # Second COW fork stage
    # Receives items from parent (via Queue) after Stage1
    cow_fork(2) do
      processor :stage2 do |item, output|
        pid = Process.pid
        puts "[Stage2:cow_fork] Processing #{item[:id]} in ephemeral fork PID #{pid}"

        # Item is COW-shared (no serialization overhead for input)
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
  puts 'Example: COW Fork -> COW Fork Routing'
  puts '=' * 80
  puts ''

  example = CowToCowForkExample.new
  begin
    example.run

    puts "\n#{'=' * 80}"
    puts 'Results:'
    puts "  Items processed: #{example.results.size}"
    puts '  Expected: 8'

    stage1_pids = example.results.map { |r| r[:stage1_pid] }.uniq.sort
    stage2_pids = example.results.map { |r| r[:stage2_pid] }.uniq.sort

    puts "  Stage1 PIDs: #{stage1_pids.join(', ')} (#{stage1_pids.size} ephemeral forks)"
    puts "  Stage2 PIDs: #{stage2_pids.join(', ')} (#{stage2_pids.size} ephemeral forks)"

    success = example.results.size == 8 &&
              example.results.all? { |r| r[:stage1_processed] && r[:stage2_processed] }

    puts "  Status: #{success ? '✓ SUCCESS' : '✗ FAILED'}"
    puts '=' * 80
    puts ''
    puts 'Key Points:'
    puts '  - Two sequential COW fork stages'
    puts '  - Each stage: one ephemeral fork per item'
    puts '  - Serialization boundaries:'
    puts '    1. Parent -> Stage1 forks (COW-shared, no serialization)'
    puts '    2. Stage1 forks -> Parent (IPC serialization)'
    puts '    3. Parent -> Stage2 forks (COW-shared, no serialization)'
    puts '    4. Stage2 forks -> Parent (IPC serialization)'
    puts '  - Efficient for large inputs (COW optimization)'
    puts '  - Many ephemeral processes created and reaped'
    puts '  - Good for: CPU-intensive work with large data structures'
    puts '=' * 80
  rescue NotImplementedError => e
    puts "\nForking not available on this platform: #{e.message}"
    puts '(This is expected on Windows)'
  end
end
