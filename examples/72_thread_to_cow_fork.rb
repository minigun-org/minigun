#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

# Example: Thread to COW Fork Routing (Terminal Consumer)
#
# Demonstrates cross-boundary routing from threaded execution to COW fork execution.
# Data flows from thread pool -> COW fork pool via COW-shared memory.
#
# Architecture:
# - Producer (inline) -> Processor (threads) -> Consumer (COW fork)
# - Thread stage writes results to Queue in parent
# - COW fork reads from Queue, forks with COW-shared item
# - Since this is terminal, NO IPC result sending needed
#
# Key Difference from IPC:
# - COW: Item is COW-shared (no input serialization)
# - IPC: Item is serialized to worker via pipes

class ThreadToCowForkExample
  include Minigun::DSL

  attr_reader :results

  def initialize
    @results = []
    @results_file = "/tmp/minigun_thread_to_cow_#{Process.pid}.txt"
  end

  def cleanup
    File.unlink(@results_file) if File.exist?(@results_file)
  end

  pipeline do
    # Producer generates data in master process
    producer :generate do |output|
      puts "[Producer] Generating 10 items in master process (PID #{Process.pid})"
      10.times do |i|
        output << { id: i + 1, value: (i + 1) * 10 }
      end
    end

    # Processor runs in thread pool
    thread_pool(3) do
      processor :enrich do |item, output|
        puts "[Processor:thread_pool] Processing #{item[:id]} in thread #{Thread.current.object_id}"
        enriched = item.merge(
          enriched_at: Time.now.to_i,
          thread_id: Thread.current.object_id
        )
        output << enriched
      end
    end

    # Consumer runs in COW fork pool
    # Item is COW-shared (no serialization overhead for input)
    cow_fork(2) do
      consumer :save do |item|
        puts "[Consumer:cow_fork] Saving #{item[:id]} in forked process (PID #{Process.pid})"

        # Can access the full item structure via COW (no serialization)
        # Write to temp file (fork-safe with file locking)
        File.open(@results_file, 'a') do |f|
          f.flock(File::LOCK_EX)
          f.puts "#{item[:id]}:#{item[:value]}:#{Process.pid}"
          f.flock(File::LOCK_UN)
        end

        sleep 0.05 # Simulate I/O work
      end
    end

    after_run do
      # Read results from temp file
      if File.exist?(@results_file)
        @results = File.readlines(@results_file).map do |line|
          id, value, pid = line.strip.split(':')
          { id: id.to_i, value: value.to_i, pid: pid.to_i }
        end
      end
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  puts "=" * 80
  puts "Example: Thread to COW Fork Routing (Terminal Consumer)"
  puts "=" * 80
  puts ""

  example = ThreadToCowForkExample.new
  begin
    example.run

    puts "\n" + "=" * 80
    puts "Results:"
    puts "  Items processed: #{example.results.size}"
    puts "  Expected: 10"
    puts "  PIDs used: #{example.results.map { |r| r[:pid] }.uniq.sort.join(', ')}"

    success = example.results.size == 10 &&
              example.results.map { |r| r[:id] }.sort == (1..10).to_a

    puts "  Status: #{success ? '✓ SUCCESS' : '✗ FAILED'}"
    puts "=" * 80
    puts ""
    puts "Key Points:"
    puts "  - Producer runs inline in master process"
    puts "  - Processor runs in thread pool (shared memory)"
    puts "  - Consumer runs in COW fork pool"
    puts "  - Data flows: master -> threads -> Queue -> COW fork"
    puts "  - COW fork: item is COW-shared (NO input serialization)"
    puts "  - One fork per item, each fork exits after processing"
    puts "  - Since terminal consumer, NO IPC result sending"
    puts "  - More efficient than IPC for input (no Marshal overhead)"
    puts "=" * 80
  rescue NotImplementedError => e
    puts "\nForking not available on this platform: #{e.message}"
    puts "(This is expected on Windows)"
  end
end
