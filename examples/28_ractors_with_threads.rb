#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

# Demonstrates combining Ractors with thread pools in the same pipeline
#
# Use Case: CPU-bound Ractor stage followed by I/O-bound thread stage
# - Ractors: True parallelism for CPU-intensive work (bypasses GIL)
# - Threads: Good for I/O-bound work (network, file I/O)
#
# Architecture:
#   Producer -> [Ractors: CPU work] -> [Threads: I/O work] -> Consumer
#
class RactorsWithThreads
  include Minigun::DSL

  attr_reader :results

  def initialize
    @results = []
    @mutex = Mutex.new
  end

  pipeline do
    producer :generate do |output|
      20.times { |i| output << i }
    end

    # CPU-intensive stage using Ractors (true parallelism)
    # Blocks in in_ractors are automatically made shareable
    in_ractors(4) do
      processor :cpu_work do |item, output|
        # Simulate CPU-bound computation (runs in true parallel)
        result = (1..500).reduce(item.to_f) { |acc, _| Math.sqrt(acc**2 + 1) }
        output << { original: item, computed: result.round(4) }
      end
    end

    # I/O-bound stage using threads (GIL-friendly for I/O)
    in_threads(4) do
      processor :io_work do |item, output|
        # Simulate I/O operation (threads release GIL during sleep)
        sleep 0.01
        output << item.merge(io_done: true)
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

  puts '=== Ractors + Threads Pipeline ==='
  puts 'Stage 1: CPU-intensive work in Ractors (true parallelism)'
  puts 'Stage 2: I/O-bound work in Threads (GIL-friendly)'
  puts

  example = RactorsWithThreads.new
  start = Time.now
  example.run
  elapsed = Time.now - start

  puts "Processed #{example.results.size} items in #{elapsed.round(3)}s"
  puts "Sample results:"
  example.results.sort_by { |r| r[:original] }.first(5).each do |r|
    puts "  #{r[:original]} -> computed: #{r[:computed]}, io_done: #{r[:io_done]}"
  end
end
