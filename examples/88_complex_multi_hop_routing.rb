#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

# Example: Complex Multi-Hop Cross-Boundary Routing
#
# Demonstrates a complex pipeline with multiple cross-boundary hops:
# - Master -> Threads -> IPC Forks -> COW Forks -> Threads -> Master
# - Shows multiple serialization boundaries
# - Demonstrates all executor types in one pipeline
#
# Architecture:
# Producer (inline)
#   -> Validator (threads)
#   -> Heavy Compute (IPC fork)
#   -> Transform (COW fork)
#   -> Aggregator (threads)
#   -> Collector (inline)

class ComplexMultiHopRoutingExample
  include Minigun::DSL

  attr_reader :results

  def initialize
    @results = []
    @mutex = Mutex.new
  end

  pipeline do
    # Stage 1: Producer in master process
    producer :generate do |output|
      puts "[1. Producer:inline] Generating 8 items in master (PID #{Process.pid})"
      8.times do |i|
        output << {
          id: i + 1,
          value: i + 1,
          stage: 'generated'
        }
      end
    end

    # Stage 2: Validator in thread pool
    thread_pool(2) do
      processor :validate do |item, output|
        thread_id = Thread.current.object_id
        puts "[2. Validator:thread_pool] Validating #{item[:id]} in thread #{thread_id}"
        sleep 0.01

        # Enrich in shared memory (threads)
        output << item.merge(
          stage: 'validated',
          validator_thread: thread_id
        )
      end
    end

    # Stage 3: Heavy compute in IPC fork (persistent workers)
    ipc_fork(2) do
      processor :heavy_compute do |item, output|
        pid = Process.pid
        puts "[3. HeavyCompute:ipc_fork] Computing #{item[:id]} in IPC worker PID #{pid}"
        sleep 0.02

        # Data serialized in via IPC, out via IPC
        output << item.merge(
          stage: 'computed',
          compute_pid: pid,
          computed_value: item[:value]**2
        )
      end
    end

    # Stage 4: Transform in COW fork (ephemeral forks)
    cow_fork(2) do
      processor :transform do |item, output|
        pid = Process.pid
        puts "[4. Transform:cow_fork] Transforming #{item[:id]} in COW fork PID #{pid}"
        sleep 0.02

        # Input COW-shared, output via IPC
        output << item.merge(
          stage: 'transformed',
          transform_pid: pid,
          transformed_value: item[:computed_value] + 100
        )
      end
    end

    # Stage 5: Aggregator in thread pool
    thread_pool(2) do
      processor :aggregate do |item, output|
        thread_id = Thread.current.object_id
        puts "[5. Aggregator:thread_pool] Aggregating #{item[:id]} in thread #{thread_id}"
        sleep 0.01

        # Aggregate in shared memory (threads)
        output << item.merge(
          stage: 'aggregated',
          aggregator_thread: thread_id
        )
      end
    end

    # Stage 6: Collector in master process (inline)
    consumer :collect do |item|
      puts "[6. Collector:inline] Collecting #{item[:id]} in master (PID #{Process.pid})"

      @mutex.synchronize do
        @results << item
      end
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  puts '=' * 80
  puts 'Example: Complex Multi-Hop Cross-Boundary Routing'
  puts '=' * 80
  puts ''

  example = ComplexMultiHopRoutingExample.new
  begin
    example.run

    puts "\n#{'=' * 80}"
    puts 'Results:'
    puts "  Items processed: #{example.results.size} (expected: 8)"

    validator_threads = example.results.map { |r| r[:validator_thread] }.uniq
    compute_pids = example.results.map { |r| r[:compute_pid] }.uniq.sort
    transform_pids = example.results.map { |r| r[:transform_pid] }.uniq.sort
    aggregator_threads = example.results.map { |r| r[:aggregator_thread] }.uniq

    puts "  Validator threads: #{validator_threads.size}"
    puts "  Compute PIDs: #{compute_pids.join(', ')} (#{compute_pids.size} IPC workers)"
    puts "  Transform PIDs: #{transform_pids.size} (COW forks)"
    puts "  Aggregator threads: #{aggregator_threads.size}"

    success = example.results.size == 8 &&
              example.results.all? { |r| r[:stage] == 'aggregated' }

    puts "  Status: #{success ? '✓ SUCCESS' : '✗ FAILED'}"
    puts '=' * 80
    puts ''
    puts 'Cross-Boundary Hops:'
    puts '  1. Master -> Threads (shared memory)'
    puts '  2. Threads -> IPC fork (serialization in parent)'
    puts '  3. IPC fork -> COW fork (IPC out -> Queue -> COW in)'
    puts '  4. COW fork -> Threads (IPC out -> Queue -> shared memory)'
    puts '  5. Threads -> Master (shared memory)'
    puts ''
    puts 'Serialization Boundaries:'
    puts '  - Master -> IPC workers (Marshal via pipes)'
    puts '  - IPC workers -> Master (Marshal via pipes)'
    puts '  - Master -> COW forks (COW-shared, no serialization)'
    puts '  - COW forks -> Master (Marshal via pipes)'
    puts ''
    puts 'Key Points:'
    puts '  - 6 stages with 5 cross-boundary hops'
    puts '  - All executor types: inline, threads, ipc_fork, cow_fork'
    puts '  - Parent orchestrates all routing via Queues'
    puts '  - Demonstrates complex dataflow topologies'
    puts '  - Real-world pipelines often use this pattern'
    puts '=' * 80
  rescue NotImplementedError => e
    puts "\nForking not available on this platform: #{e.message}"
    puts '(This is expected on Windows)'
  end
end
