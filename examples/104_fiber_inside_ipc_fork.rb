#!/usr/bin/env ruby
# frozen_string_literal: true

# Example 104: Fibers with IPC Forks
#
# Demonstrates using IPC forks for CPU-heavy work distributed across processes,
# then fibers for I/O-bound work. This is the recommended pattern for
# combining parallelism (forks) with concurrency (fibers).

require_relative '../lib/minigun'

puts '=' * 60
puts 'Fibers with IPC Forks'
puts '=' * 60

unless Minigun::Platform.fibers?
  puts "\n⚠️  The 'async' gem is not installed."
  exit 1
end

unless Minigun::Platform.fork?
  puts "\n⚠️  Process forking not available on this platform."
  exit 1
end

# Pipeline using IPC forks for CPU work, then fibers for I/O work
class FiberWithIpcFork
  include Minigun::DSL

  attr_reader :results

  def initialize
    @results = []
    @mutex = Mutex.new
  end

  pipeline do
    produce_each :items, (1..20).to_a

    # IPC forks for CPU-heavy parallel processing
    in_ipc_forks(2) do
      processor :cpu_work do |item, output|
        # Simulate CPU-intensive work that benefits from true parallelism
        result = (1..10_000).reduce(0) { |sum, n| sum + Math.sqrt(n) }
        output << {
          value: item,
          fork_pid: Process.pid,
          cpu_result: result.round(2)
        }
      end
    end

    # Fibers for I/O-bound work (runs in main process)
    in_fibers(10) do
      processor :io_work do |item, output|
        # Simulate async I/O (HTTP, DB, etc.)
        sleep 0.02
        item[:io_done] = true
        item[:io_at] = Time.now.to_f
        output << item
      end
    end

    consumer :collect do |item|
      @mutex.synchronize { @results << item }
    end
  end

  def cleanup
    GC.start
  end
end

start_time = Time.now
pipeline = FiberWithIpcFork.new
pipeline.run
elapsed = Time.now - start_time

puts "\nResults:"
puts "  Processed: #{pipeline.results.size} items"
fork_pids = pipeline.results.map { |r| r[:fork_pid] }.uniq
puts "  Fork worker PIDs: #{fork_pids.join(', ')}"
puts "  Items per fork: #{pipeline.results.group_by { |r| r[:fork_pid] }.transform_values(&:size)}"
puts "  All I/O done: #{pipeline.results.all? { |r| r[:io_done] }}"
puts "  Elapsed: #{elapsed.round(3)}s"
puts "\n✓ IPC forks for CPU parallelism (#{fork_pids.size} workers)"
puts '✓ Fibers for I/O concurrency (10 concurrent)'
puts '✓ Best of both worlds: parallelism + concurrency'

pipeline.cleanup
