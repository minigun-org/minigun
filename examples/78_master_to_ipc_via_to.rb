#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

# Example: Master to IPC Fork Routing (via output.to())
#
# Demonstrates explicit routing from master process to IPC fork stages using output.to().
# This bypasses sequential routing and directly targets specific stages.
#
# Architecture:
# - Producer (inline) routes explicitly to IPC fork stages via output.to(:stage_name)
# - IPC fork stages receive items directly (not via sequential flow)
# - Useful for conditional routing, broadcasting, or non-linear DAGs

class MasterToIpcViaToExample
  include Minigun::DSL

  attr_reader :results_a, :results_b

  def initialize
    @results_a = []
    @results_b = []
    @mutex = Mutex.new
  end

  pipeline do
    # Producer explicitly routes to specific IPC fork stages
    producer :generate do |output|
      puts "[Producer] Generating 10 items with explicit routing (PID #{Process.pid})"

      10.times do |i|
        item = { id: i + 1, value: (i + 1) * 10 }

        # Explicit routing: route even IDs to :process_a, odd IDs to :process_b
        if item[:id].even?
          puts "  Routing #{item[:id]} to :process_a"
          output.to(:process_a) << item
        else
          puts "  Routing #{item[:id]} to :process_b"
          output.to(:process_b) << item
        end
      end
    end

    # IPC fork stage A - receives even IDs
    ipc_fork(2) do
      consumer :process_a do |item|
        pid = Process.pid
        puts "[ProcessA:ipc_fork] Processing #{item[:id]} in PID #{pid}"
        sleep 0.03

        @mutex.synchronize do
          @results_a << item.merge(worker_pid: pid)
        end
      end
    end

    # IPC fork stage B - receives odd IDs
    ipc_fork(2) do
      consumer :process_b do |item|
        pid = Process.pid
        puts "[ProcessB:ipc_fork] Processing #{item[:id]} in PID #{pid}"
        sleep 0.03

        @mutex.synchronize do
          @results_b << item.merge(worker_pid: pid)
        end
      end
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  puts "=" * 80
  puts "Example: Master to IPC Fork Routing (via output.to())"
  puts "=" * 80
  puts ""

  example = MasterToIpcViaToExample.new
  begin
    example.run

    puts "\n" + "=" * 80
    puts "Results:"
    puts "  ProcessA received: #{example.results_a.size} items (expected: 5 even IDs)"
    puts "  ProcessB received: #{example.results_b.size} items (expected: 5 odd IDs)"

    a_ids = example.results_a.map { |r| r[:id] }.sort
    b_ids = example.results_b.map { |r| r[:id] }.sort

    puts "  ProcessA IDs: #{a_ids.inspect}"
    puts "  ProcessB IDs: #{b_ids.inspect}"

    success = example.results_a.size == 5 &&
              example.results_b.size == 5 &&
              a_ids == [2, 4, 6, 8, 10] &&
              b_ids == [1, 3, 5, 7, 9]

    puts "  Status: #{success ? '✓ SUCCESS' : '✗ FAILED'}"
    puts "=" * 80
    puts ""
    puts "Key Points:"
    puts "  - Producer uses output.to(:stage_name) for explicit routing"
    puts "  - Bypasses sequential pipeline flow"
    puts "  - Enables conditional routing, load balancing, partitioning"
    puts "  - IPC fork stages receive items directly from master"
    puts "  - Serialization boundary: master -> IPC workers via pipes"
    puts "  - Useful for: content-based routing, sharding, A/B testing"
    puts "=" * 80
  rescue NotImplementedError => e
    puts "\nForking not available on this platform: #{e.message}"
    puts "(This is expected on Windows)"
  end
end
