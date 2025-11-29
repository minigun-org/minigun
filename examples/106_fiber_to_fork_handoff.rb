#!/usr/bin/env ruby
# frozen_string_literal: true

# Example 106: Fiber to Fork Handoff
#
# Demonstrates a pipeline where fibers handle I/O-bound work
# then hand off to forks for CPU-intensive processing

require_relative '../lib/minigun'

puts '=' * 60
puts 'Fiber to Fork Handoff'
puts '=' * 60

unless Minigun::Platform.async?
  puts "\n⚠️  The 'async' gem is not installed."
  exit 1
end

unless Minigun::Platform.fork?
  puts "\n⚠️  Process forking not available on this platform."
  exit 1
end

# Pipeline where fibers handle I/O, then hand off to forks for CPU work
class FiberToForkHandoff
  include Minigun::DSL

  attr_reader :results

  def initialize
    @results = []
    @mutex = Mutex.new
  end

  pipeline do
    produce_each :items, (1..12).to_a

    # Stage 1: Fibers for I/O-bound data fetching
    in_fibers(6) do
      processor :fetch_data do |item, output|
        # Simulate fetching data from external API
        sleep 0.02
        output << {
          id: item,
          data: Array.new(1000) { rand(100) }, # Simulated fetched data
          fetched_at: Time.now.to_f
        }
      end
    end

    # Stage 2: IPC Forks for CPU-intensive processing
    in_ipc_forks(2) do
      processor :heavy_computation do |item, output|
        # CPU-intensive work benefits from true parallelism via forks
        result = item[:data].sum { |n| Math.sqrt(n) }
        item[:computed_sum] = result
        item[:computed_by_pid] = Process.pid
        output << item
      end
    end

    # Stage 3: Back to fibers for final I/O
    in_fibers(4) do
      processor :store_results do |item, output|
        # Simulate storing results
        sleep 0.01
        item[:stored] = true
        item[:stored_at] = Time.now.to_f
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
pipeline = FiberToForkHandoff.new
pipeline.run
elapsed = Time.now - start_time

puts "\nResults:"
puts "  Processed: #{pipeline.results.size} items"
puts "  All fetched: #{pipeline.results.all? { |r| r[:fetched_at] }}"
puts "  All computed: #{pipeline.results.all? { |r| r[:computed_sum] }}"
puts "  All stored: #{pipeline.results.all? { |r| r[:stored] }}"

fork_pids = pipeline.results.map { |r| r[:computed_by_pid] }.uniq
puts "  Fork workers used: #{fork_pids.size} PIDs"
puts "  Elapsed: #{elapsed.round(3)}s"
puts "\n✓ Fibers for I/O -> Forks for CPU -> Fibers for I/O"
puts "✓ Each execution strategy used where it's most effective"

pipeline.cleanup
