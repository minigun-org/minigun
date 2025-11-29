#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

# Demonstrates combining Ractors with fiber pools in the same pipeline
#
# Use Case: CPU-bound Ractor stage followed by async I/O fiber stage
# - Ractors: True parallelism for CPU-intensive work
# - Fibers: Lightweight concurrency for async I/O (requires async gem)
#
# Architecture:
#   Producer -> [Ractors: CPU work] -> [Fibers: async I/O] -> Consumer
#
# Note: Fiber pools require the 'async' gem. On Ruby 4.0+ with fiber scheduler,
# fibers can efficiently handle thousands of concurrent I/O operations.
#
class RactorsWithFibers
  include Minigun::DSL

  attr_reader :results

  def initialize
    @results = []
    @mutex = Mutex.new
  end

  pipeline do
    producer :generate do |output|
      15.times { |i| output << i }
    end

    # CPU-intensive stage using Ractors
    in_ractors(3) do
      processor :compute do |item, output|
        # Heavy computation benefits from true parallelism
        result = (1..300).reduce(item.to_f) { |acc, _| Math.sqrt(acc**2 + 1) }
        output << { id: item, computed: result.round(4) }
      end
    end

    # Async I/O stage using fibers (lightweight concurrency)
    in_fibers(10) do
      processor :async_io do |item, output|
        # Simulate async I/O - fibers yield during sleep
        sleep 0.02
        output << item.merge(async_done: true, fiber_id: Fiber.current.object_id)
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

  puts '=== Ractors + Fibers Pipeline ==='
  puts 'Stage 1: CPU-intensive work in Ractors'
  puts 'Stage 2: Async I/O in Fibers (lightweight concurrency)'
  puts

  example = RactorsWithFibers.new
  start = Time.now
  example.run
  elapsed = Time.now - start

  puts "Processed #{example.results.size} items in #{elapsed.round(3)}s"

  # Show fiber distribution
  fiber_ids = example.results.map { |r| r[:fiber_id] }.uniq
  puts "Used #{fiber_ids.size} different fibers"

  puts "Sample results:"
  example.results.sort_by { |r| r[:id] }.first(5).each do |r|
    puts "  #{r[:id]} -> computed: #{r[:computed]}, async: #{r[:async_done]}"
  end
end
