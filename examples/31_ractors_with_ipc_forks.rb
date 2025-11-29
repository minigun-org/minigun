#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

# Demonstrates combining Ractors with IPC (Inter-Process Communication) forks
#
# Use Case: CPU-bound Ractor stage followed by fully isolated fork processes
# - Ractors: True parallelism for CPU-intensive work within a single process
# - IPC Forks: Fully isolated processes with serialized message passing
#
# Architecture:
#   Producer -> [Ractors: CPU work] -> [IPC Forks: isolated processing] -> Consumer
#
# IPC forks use Marshal serialization to pass data between parent and child processes.
# This provides complete isolation but has serialization overhead. Good for:
# - Untrusted code execution
# - Memory leak isolation
# - Complete crash isolation
#
class RactorsWithIpcForks
  include Minigun::DSL

  attr_reader :results

  def initialize
    @results = []
    @mutex = Mutex.new
  end

  pipeline do
    producer :generate do |output|
      10.times { |i| output << i }
    end

    # CPU-intensive stage using Ractors (true parallelism)
    in_ractors(3) do
      processor :compute do |item, output|
        # Heavy computation benefits from bypassing GIL
        result = (1..350).reduce(item.to_f) { |acc, _| Math.sqrt((acc**2) + 1) }
        output << { id: item, computed: result.round(4) }
      end
    end

    # Fully isolated processing in IPC forks
    # Data is serialized via Marshal between parent and child
    in_ipc_forks(3) do
      processor :isolated_work do |item, output|
        # This runs in a completely separate process
        # Good for isolation but has serialization overhead
        sleep 0.02
        output << item.merge(
          isolated: true,
          pid: Process.pid,
          memory_isolated: true
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

  puts '=== Ractors + IPC Forks Pipeline ==='
  puts 'Stage 1: CPU-intensive work in Ractors (true parallelism)'
  puts 'Stage 2: Fully isolated processing in IPC forks (serialized IPC)'
  puts

  example = RactorsWithIpcForks.new
  start = Time.now
  example.run
  elapsed = Time.now - start

  puts "Processed #{example.results.size} items in #{elapsed.round(3)}s"

  # Show fork distribution
  pids = example.results.map { |r| r[:pid] }.uniq
  puts "Used #{pids.size} different IPC fork processes"

  puts 'Sample results:'
  example.results.sort_by { |r| r[:id] }.first(5).each do |r|
    puts "  #{r[:id]} -> computed: #{r[:computed]}, isolated: #{r[:isolated]}, pid: #{r[:pid]}"
  end
end
