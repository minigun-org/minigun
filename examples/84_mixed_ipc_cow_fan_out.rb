#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

# Example: Mixed IPC/COW Fork Fan-Out Pattern
#
# Demonstrates routing from one stage to multiple downstream stages
# using BOTH IPC fork and COW fork execution models.
# Shows heterogeneous cross-boundary routing.
#
# Architecture:
# - Producer -> Splitter (threads) -> [IPC Fork A, COW Fork B, IPC Fork C]
# - Splitter routes to different fork types based on content
# - Demonstrates mixing persistent (IPC) and ephemeral (COW) workers

class MixedIpcCowFanOutExample
  include Minigun::DSL

  attr_reader :results_ipc_a, :results_cow_b, :results_ipc_c

  def initialize
    @results_ipc_a = []
    @results_ipc_c = []
    @results_cow_b = []
    @results_ipc_a_file = "/tmp/minigun_84_ipc_a_#{Process.pid}.txt"
    @results_ipc_c_file = "/tmp/minigun_84_ipc_c_#{Process.pid}.txt"
    @results_cow_file = "/tmp/minigun_84_cow_b_#{Process.pid}.txt"
  end

  def cleanup
    FileUtils.rm_f(@results_ipc_a_file)
    FileUtils.rm_f(@results_ipc_c_file)
    FileUtils.rm_f(@results_cow_file)
  end

  pipeline do
    # Producer generates data
    producer :generate do |output|
      puts "[Producer] Generating 12 items (PID #{Process.pid})"
      12.times do |i|
        output << { id: i + 1, value: i + 1 }
      end
    end

    # Splitter stage in threads - routes to different fork types
    thread_pool(2) do
      processor :splitter do |item, output|
        thread_id = Thread.current.object_id
        puts "[Splitter:thread_pool] Routing #{item[:id]} in thread #{thread_id}"

        # Route based on modulo: 0->IPC A, 1->COW B, 2->IPC C
        case item[:id] % 3
        when 0
          output.to(:process_ipc_a) << item.merge(routed_to: 'IPC_A', thread_id: thread_id)
        when 1
          output.to(:process_cow_b) << item.merge(routed_to: 'COW_B', thread_id: thread_id)
        when 2
          output.to(:process_ipc_c) << item.merge(routed_to: 'IPC_C', thread_id: thread_id)
        end
      end
    end

    # IPC fork consumer A (persistent workers)
    ipc_fork(1) do
      consumer :process_ipc_a do |item|
        pid = Process.pid
        puts "[ProcessIpcA:ipc_fork] Processing #{item[:id]} in persistent worker PID #{pid}"
        sleep 0.03

        File.open(@results_ipc_a_file, 'a') do |f|
          f.flock(File::LOCK_EX)
          f.puts "#{item[:id]}:#{item[:routed_to]}:#{pid}:IPC"
          f.flock(File::LOCK_UN)
        end
      end
    end

    # COW fork consumer B (ephemeral forks)
    cow_fork(2) do
      consumer :process_cow_b do |item|
        pid = Process.pid
        puts "[ProcessCowB:cow_fork] Processing #{item[:id]} in ephemeral fork PID #{pid}"
        sleep 0.03

        # COW-shared input, write to file
        File.open(@results_cow_file, 'a') do |f|
          f.flock(File::LOCK_EX)
          f.puts "#{item[:id]}:#{item[:routed_to]}:#{pid}:COW"
          f.flock(File::LOCK_UN)
        end
      end
    end

    # IPC fork consumer C (persistent workers)
    ipc_fork(1) do
      consumer :process_ipc_c do |item|
        pid = Process.pid
        puts "[ProcessIpcC:ipc_fork] Processing #{item[:id]} in persistent worker PID #{pid}"
        sleep 0.03

        File.open(@results_ipc_c_file, 'a') do |f|
          f.flock(File::LOCK_EX)
          f.puts "#{item[:id]}:#{item[:routed_to]}:#{pid}:IPC"
          f.flock(File::LOCK_UN)
        end
      end
    end

    after_run do
      # Read results from temp files
      if File.exist?(@results_ipc_a_file)
        @results_ipc_a = File.readlines(@results_ipc_a_file).map do |line|
          id, routed_to, worker_pid, fork_type = line.strip.split(':')
          { id: id.to_i, routed_to: routed_to, worker_pid: worker_pid.to_i, fork_type: fork_type }
        end
      end

      if File.exist?(@results_cow_file)
        @results_cow_b = File.readlines(@results_cow_file).map do |line|
          id, routed_to, worker_pid, fork_type = line.strip.split(':')
          { id: id.to_i, routed_to: routed_to, worker_pid: worker_pid.to_i, fork_type: fork_type }
        end
      end

      if File.exist?(@results_ipc_c_file)
        @results_ipc_c = File.readlines(@results_ipc_c_file).map do |line|
          id, routed_to, worker_pid, fork_type = line.strip.split(':')
          { id: id.to_i, routed_to: routed_to, worker_pid: worker_pid.to_i, fork_type: fork_type }
        end
      end
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  puts '=' * 80
  puts 'Example: Mixed IPC/COW Fork Fan-Out Pattern'
  puts '=' * 80
  puts ''

  example = MixedIpcCowFanOutExample.new
  begin
    example.run

    puts "\n#{'=' * 80}"
    puts 'Results:'
    puts "  ProcessIpcA received: #{example.results_ipc_a.size} items (expected: 4)"
    puts "  ProcessCowB received: #{example.results_cow_b.size} items (expected: 4)"
    puts "  ProcessIpcC received: #{example.results_ipc_c.size} items (expected: 4)"

    ipc_a_ids = example.results_ipc_a.map { |r| r[:id] }.sort
    cow_b_ids = example.results_cow_b.map { |r| r[:id] }.sort
    ipc_c_ids = example.results_ipc_c.map { |r| r[:id] }.sort

    puts "  ProcessIpcA IDs: #{ipc_a_ids.inspect}"
    puts "  ProcessCowB IDs: #{cow_b_ids.inspect}"
    puts "  ProcessIpcC IDs: #{ipc_c_ids.inspect}"

    success = example.results_ipc_a.size == 4 &&
              example.results_cow_b.size == 4 &&
              example.results_ipc_c.size == 4 &&
              ipc_a_ids == [3, 6, 9, 12] &&
              cow_b_ids == [1, 4, 7, 10] &&
              ipc_c_ids == [2, 5, 8, 11]

    puts "  Status: #{success ? '✓ SUCCESS' : '✗ FAILED'}"
    puts '=' * 80
    puts ''
    puts 'Key Points:'
    puts '  - Mixed fan-out: threads -> [IPC, COW, IPC]'
    puts '  - Different execution models in same pipeline'
    puts '  - IPC: Persistent workers, full serialization'
    puts '  - COW: Ephemeral forks, COW-shared inputs'
    puts '  - Choose executor based on workload characteristics:'
    puts '    * IPC: Long-running connections, state'
    puts '    * COW: CPU-intensive, large read-only data'
    puts '  - Useful for: heterogeneous workloads, optimization'
    puts '=' * 80
  rescue NotImplementedError => e
    puts "\nForking not available on this platform: #{e.message}"
    puts '(This is expected on Windows)'
  ensure
    example.cleanup
  end
end
