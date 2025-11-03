#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

# Example: IPC Fork Fan-Out Pattern
#
# Demonstrates one IPC fork stage routing to multiple downstream IPC fork stages.
# Shows cross-boundary routing with fan-out topology.
#
# Architecture:
# - Producer -> IPC Stage (splitter) -> [IPC Stage A, IPC Stage B, IPC Stage C]
# - Splitter routes items to different stages based on content
# - All stages use persistent IPC workers
# - Full serialization at all boundaries

class IpcFanOutExample
  include Minigun::DSL

  attr_reader :results_a, :results_b, :results_c

  def initialize
    @results_a = []
    @results_b = []
    @results_c = []
    @mutex = Mutex.new
  end

  pipeline do
    # Producer generates data
    producer :generate do |output|
      puts "[Producer] Generating 12 items (PID #{Process.pid})"
      12.times do |i|
        output << { id: i + 1, value: i + 1 }
      end
    end

    # Splitter stage in IPC fork - routes to different stages
    ipc_fork(2) do
      processor :splitter do |item, output|
        pid = Process.pid
        puts "[Splitter:ipc_fork] Routing #{item[:id]} in PID #{pid}"

        # Route based on modulo: 0->A, 1->B, 2->C
        case item[:id] % 3
        when 0
          output.to(:process_a) << item.merge(routed_to: 'A', splitter_pid: pid)
        when 1
          output.to(:process_b) << item.merge(routed_to: 'B', splitter_pid: pid)
        when 2
          output.to(:process_c) << item.merge(routed_to: 'C', splitter_pid: pid)
        end
      end
    end

    # Three IPC fork consumer stages (fan-out targets)
    ipc_fork(1) do
      consumer :process_a do |item|
        pid = Process.pid
        puts "[ProcessA:ipc_fork] Processing #{item[:id]} in PID #{pid}"
        sleep 0.03

        @mutex.synchronize do
          @results_a << item.merge(worker_pid: pid)
        end
      end
    end

    ipc_fork(1) do
      consumer :process_b do |item|
        pid = Process.pid
        puts "[ProcessB:ipc_fork] Processing #{item[:id]} in PID #{pid}"
        sleep 0.03

        @mutex.synchronize do
          @results_b << item.merge(worker_pid: pid)
        end
      end
    end

    ipc_fork(1) do
      consumer :process_c do |item|
        pid = Process.pid
        puts "[ProcessC:ipc_fork] Processing #{item[:id]} in PID #{pid}"
        sleep 0.03

        @mutex.synchronize do
          @results_c << item.merge(worker_pid: pid)
        end
      end
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  puts "=" * 80
  puts "Example: IPC Fork Fan-Out Pattern"
  puts "=" * 80
  puts ""

  example = IpcFanOutExample.new
  begin
    example.run

    puts "\n" + "=" * 80
    puts "Results:"
    puts "  ProcessA received: #{example.results_a.size} items (expected: 4)"
    puts "  ProcessB received: #{example.results_b.size} items (expected: 4)"
    puts "  ProcessC received: #{example.results_c.size} items (expected: 4)"

    a_ids = example.results_a.map { |r| r[:id] }.sort
    b_ids = example.results_b.map { |r| r[:id] }.sort
    c_ids = example.results_c.map { |r| r[:id] }.sort

    puts "  ProcessA IDs: #{a_ids.inspect}"
    puts "  ProcessB IDs: #{b_ids.inspect}"
    puts "  ProcessC IDs: #{c_ids.inspect}"

    success = example.results_a.size == 4 &&
              example.results_b.size == 4 &&
              example.results_c.size == 4 &&
              a_ids == [3, 6, 9, 12] &&
              b_ids == [1, 4, 7, 10] &&
              c_ids == [2, 5, 8, 11]

    puts "  Status: #{success ? '✓ SUCCESS' : '✗ FAILED'}"
    puts "=" * 80
    puts ""
    puts "Key Points:"
    puts "  - Fan-out from IPC splitter to 3 IPC consumers"
    puts "  - Splitter makes routing decisions in IPC worker"
    puts "  - Content-based routing (by ID modulo)"
    puts "  - Serialization boundaries:"
    puts "    1. Parent -> Splitter workers (IPC)"
    puts "    2. Splitter workers -> Parent (IPC)"
    puts "    3. Parent -> Consumer workers (IPC)"
    puts "  - All routing happens through parent's Queues"
    puts "  - Useful for: partitioning, sharding, load distribution"
    puts "=" * 80
  rescue NotImplementedError => e
    puts "\nForking not available on this platform: #{e.message}"
    puts "(This is expected on Windows)"
  end
end
