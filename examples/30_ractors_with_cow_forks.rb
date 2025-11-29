#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

# Demonstrates combining Ractors with Copy-on-Write (COW) fork processes
#
# Use Case: CPU-bound Ractor stage followed by memory-efficient fork processing
# - Ractors: True parallelism for CPU-intensive work within a single process
# - COW Forks: Memory-efficient isolated processes that share read-only data
#
# Architecture:
#   Producer -> [Ractors: CPU work] -> [COW Forks: isolated heavy processing] -> Consumer
#
# Note: COW forks share memory with the parent until they write, making them
# efficient for read-heavy workloads where child processes mostly read shared data.
#
class RactorsWithCowForks
  include Minigun::DSL

  attr_reader :results

  def initialize
    @results = []
    @mutex = Mutex.new
    # Shared read-only data - COW forks can read this efficiently
    @lookup_table = (0..100).to_h { |i| [i, "value_#{i}"] }.freeze
  end

  pipeline do
    producer :generate do |output|
      12.times { |i| output << i }
    end

    # CPU-intensive stage using Ractors (true parallelism)
    in_ractors(3) do
      processor :compute do |item, output|
        # Heavy computation benefits from bypassing GIL
        result = (1..400).reduce(item.to_f) { |acc, _| Math.sqrt((acc**2) + 1) }
        output << { id: item, computed: result.round(4) }
      end
    end

    # Memory-efficient processing in COW forks
    # Each fork shares the parent's memory until it writes
    in_cow_forks(3) do
      processor :enrich do |item, output|
        # Read from shared lookup table (COW - no memory copy)
        lookup_value = @lookup_table[item[:id] % 100]
        # Simulate some processing
        sleep 0.01
        output << item.merge(enriched: lookup_value, pid: Process.pid)
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

  puts '=== Ractors + COW Forks Pipeline ==='
  puts 'Stage 1: CPU-intensive work in Ractors (true parallelism)'
  puts 'Stage 2: Memory-efficient processing in COW forks'
  puts

  example = RactorsWithCowForks.new
  start = Time.now
  example.run
  elapsed = Time.now - start

  puts "Processed #{example.results.size} items in #{elapsed.round(3)}s"

  # Show fork distribution
  pids = example.results.map { |r| r[:pid] }.uniq
  puts "Used #{pids.size} different fork processes"

  puts 'Sample results:'
  example.results.sort_by { |r| r[:id] }.first(5).each do |r|
    puts "  #{r[:id]} -> computed: #{r[:computed]}, enriched: #{r[:enriched]}, pid: #{r[:pid]}"
  end
end
