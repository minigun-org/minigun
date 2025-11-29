#!/usr/bin/env ruby
# frozen_string_literal: true

# Example 105: Fibers with COW Fork
#
# Demonstrates using COW (Copy-On-Write) forks for isolated processing,
# then fibers for I/O-bound work. COW forks are useful when you need
# process isolation for each item (e.g., untrusted code, memory-heavy ops).

require_relative '../lib/minigun'

puts '=' * 60
puts 'Fibers with COW Fork'
puts '=' * 60

unless Minigun::Platform.async?
  puts "\n⚠️  The 'async' gem is not installed."
  exit 1
end

unless Minigun::Platform.fork?
  puts "\n⚠️  Process forking not available on this platform."
  exit 1
end

# Shared data that will be COW-shared with child processes
SHARED_LOOKUP = {
  1 => 'one', 2 => 'two', 3 => 'three', 4 => 'four', 5 => 'five',
  6 => 'six', 7 => 'seven', 8 => 'eight', 9 => 'nine', 10 => 'ten'
}.freeze

class FiberWithCowFork
  include Minigun::DSL

  attr_reader :results

  def initialize
    @results = []
    @mutex = Mutex.new
  end

  pipeline do
    produce_each :items, (1..15).to_a

    # COW fork creates short-lived processes per item batch
    # Memory is shared (COW) until modified - good for isolated processing
    in_cow_forks(3) do
      processor :isolated_process do |item, output|
        # Access COW-shared data (no copy triggered until write)
        name = SHARED_LOOKUP[item] || "number_#{item}"

        output << {
          value: item,
          name: name,
          cow_pid: Process.pid
        }
      end
    end

    # After COW isolation, use fibers for concurrent I/O
    in_fibers(5) do
      processor :async_io do |item, output|
        # Simulate async I/O (HTTP, DB, etc.)
        sleep 0.01
        item[:io_done] = true
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
pipeline = FiberWithCowFork.new
pipeline.run
elapsed = Time.now - start_time

puts "\nResults:"
puts "  Processed: #{pipeline.results.size} items"
cow_pids = pipeline.results.map { |r| r[:cow_pid] }.uniq
puts "  COW fork PIDs: #{cow_pids.size} unique processes"
puts "  All I/O done: #{pipeline.results.all? { |r| r[:io_done] }}"
puts "  Sample results:"
pipeline.results.take(5).each do |r|
  puts "    #{r[:value]} -> #{r[:name]} (cow_pid: #{r[:cow_pid]})"
end
puts "  Elapsed: #{elapsed.round(3)}s"
puts "\n✓ COW forks for process isolation"
puts "✓ Fibers for concurrent I/O after isolation"
puts "✓ Shared data accessed efficiently via Copy-On-Write"

pipeline.cleanup
