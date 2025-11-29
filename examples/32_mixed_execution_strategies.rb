#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

# Demonstrates combining ALL execution strategies in a single pipeline
#
# Use Case: Complex data processing with different concurrency needs per stage
# - Ractors: True parallelism for CPU-intensive work (bypasses GIL)
# - Threads: Lightweight concurrency for I/O-bound work
# - Fibers: Ultra-lightweight concurrency for async I/O (with async gem)
# - COW Forks: Memory-efficient isolated processes
# - IPC Forks: Fully isolated processes with serialized communication
#
# Architecture:
#   Producer -> [Ractors: CPU] -> [Threads: I/O] -> [Fibers: async] ->
#            -> [COW Forks: enrich] -> [IPC Forks: finalize] -> Consumer
#
# This demonstrates the flexibility of mixing execution strategies to optimize
# each stage for its specific workload characteristics.
#
class MixedExecutionStrategies
  include Minigun::DSL

  attr_reader :results

  def initialize
    @results = []
    @mutex = Mutex.new
    # Shared read-only data for COW forks
    @enrichment_data = (0..50).map { |i| [i, "enriched_#{i}"] }.to_h.freeze
  end

  pipeline do
    producer :generate do |output|
      8.times { |i| output << { id: i, stage: 'produced' } }
    end

    # Stage 1: CPU-intensive work in Ractors (true parallelism)
    in_ractors(2) do
      processor :cpu_compute do |item, output|
        # Heavy computation - Ractors bypass GIL
        result = (1..200).reduce(item[:id].to_f) { |acc, _| Math.sqrt(acc**2 + 1) }
        output << item.merge(computed: result.round(4), stage: 'ractor')
      end
    end

    # Stage 2: I/O-bound work in threads (GIL-friendly for I/O)
    in_threads(3) do
      processor :thread_io do |item, output|
        # Simulate I/O operation - threads release GIL during sleep
        sleep 0.01
        output << item.merge(thread_id: Thread.current.object_id, stage: 'thread')
      end
    end

    # Stage 3: Async I/O in fibers (lightweight concurrency)
    in_fibers(5) do
      processor :fiber_async do |item, output|
        # Simulate async I/O - fibers yield during sleep
        sleep 0.01
        output << item.merge(fiber_id: Fiber.current.object_id, stage: 'fiber')
      end
    end

    # Stage 4: Memory-efficient enrichment in COW forks
    in_cow_forks(2) do
      processor :cow_enrich do |item, output|
        # Read from shared data (COW - no memory copy)
        enriched = @enrichment_data[item[:id] % 50]
        sleep 0.01
        output << item.merge(enriched: enriched, cow_pid: Process.pid, stage: 'cow_fork')
      end
    end

    # Stage 5: Final isolated processing in IPC forks
    in_ipc_forks(2) do
      processor :ipc_finalize do |item, output|
        # Completely isolated - good for untrusted code or crash isolation
        sleep 0.01
        output << item.merge(
          ipc_pid: Process.pid,
          finalized: true,
          stage: 'ipc_fork'
        )
      end
    end

    consumer :collect do |item|
      @mutex.synchronize { @results << item }
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  puts "Ruby version: #{RUBY_VERSION}"
  puts "Ractor::Port available: #{Minigun::Platform.ractors?}"
  puts

  puts '=== Mixed Execution Strategies Pipeline ==='
  puts 'Stage 1: CPU work in Ractors (true parallelism)'
  puts 'Stage 2: I/O work in Threads (GIL-friendly)'
  puts 'Stage 3: Async I/O in Fibers (lightweight)'
  puts 'Stage 4: Enrichment in COW Forks (memory-efficient)'
  puts 'Stage 5: Finalization in IPC Forks (isolated)'
  puts

  example = MixedExecutionStrategies.new
  start = Time.now
  example.run
  elapsed = Time.now - start

  puts "Processed #{example.results.size} items in #{elapsed.round(3)}s"
  puts

  # Show distribution across execution contexts
  threads = example.results.map { |r| r[:thread_id] }.uniq.compact
  fibers = example.results.map { |r| r[:fiber_id] }.uniq.compact
  cow_pids = example.results.map { |r| r[:cow_pid] }.uniq.compact
  ipc_pids = example.results.map { |r| r[:ipc_pid] }.uniq.compact

  puts 'Execution distribution:'
  puts "  Threads used: #{threads.size}"
  puts "  Fibers used: #{fibers.size}"
  puts "  COW fork PIDs: #{cow_pids.size}"
  puts "  IPC fork PIDs: #{ipc_pids.size}"
  puts

  puts 'Sample results:'
  example.results.sort_by { |r| r[:id] }.first(3).each do |r|
    puts "  ID #{r[:id]}:"
    puts "    computed: #{r[:computed]}"
    puts "    enriched: #{r[:enriched]}"
    puts "    finalized: #{r[:finalized]}"
    puts "    stages: produced -> ractor -> thread -> fiber -> cow_fork -> ipc_fork"
  end
end
