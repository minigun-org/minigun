#!/usr/bin/env ruby
# frozen_string_literal: true

# Example 103: Mixing Fibers with Threads
#
# Demonstrates combining fiber stages with thread stages in the same pipeline

require_relative '../lib/minigun'

puts '=' * 60
puts 'Mixing Fibers with Threads'
puts '=' * 60

unless Minigun::Platform.fibers?
  puts "\n⚠️  The 'async' gem is not installed."
  exit 1
end

# Pipeline combining fiber stages with thread stages
class FiberAndThreadMix
  include Minigun::DSL

  attr_reader :results, :thread_ids, :execution_info

  def initialize
    @results = []
    @thread_ids = { fiber: Set.new, thread: Set.new }
    @execution_info = []
    @mutex = Mutex.new
  end

  pipeline do
    produce_each :items, (1..20).to_a

    # Fibers: I/O-bound work (all run in same thread)
    in_fibers(5) do
      processor :io_work do |item, output|
        @mutex.synchronize { @thread_ids[:fiber] << Thread.current.object_id }
        sleep 0.01 # Simulate I/O
        output << { value: item, io_done: true }
      end
    end

    # Threads: CPU-bound work (uses multiple threads)
    in_threads(3) do
      processor :cpu_work do |item, output|
        @mutex.synchronize { @thread_ids[:thread] << Thread.current.object_id }
        # Simulate CPU work
        result = (1..1000).sum
        item[:cpu_result] = result
        output << item
      end
    end

    # Back to fibers for final I/O
    in_fibers(5) do
      processor :final_io do |item, output|
        sleep 0.005 # Final I/O operation
        item[:finalized] = true
        output << item
      end
    end

    consumer :collect do |item|
      @mutex.synchronize { @results << item }
    end
  end
end

start_time = Time.now
pipeline = FiberAndThreadMix.new
pipeline.run
elapsed = Time.now - start_time

puts "\nResults:"
puts "  Processed: #{pipeline.results.size} items"
puts "  All IO done: #{pipeline.results.all? { |r| r[:io_done] }}"
puts "  All CPU done: #{pipeline.results.all? { |r| r[:cpu_result] }}"
puts "  All finalized: #{pipeline.results.all? { |r| r[:finalized] }}"
puts "\nThread usage:"
puts "  Fiber stages used #{pipeline.thread_ids[:fiber].size} thread(s) (should be 1)"
puts "  Thread stages used #{pipeline.thread_ids[:thread].size} thread(s) (should be ~3)"
puts "  Elapsed: #{elapsed.round(3)}s"
puts "\n✓ Fibers for I/O, threads for CPU - best of both worlds"
