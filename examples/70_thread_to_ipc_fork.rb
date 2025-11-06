#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

# Example: Thread to IPC Fork Routing
#
# Demonstrates cross-boundary routing from threaded execution to IPC fork execution.
# Data flows from thread pool -> IPC fork pool via serialized IPC pipes.
#
# Architecture:
# - Producer (inline) -> Processor (threads) -> Consumer (IPC fork)
# - Thread stage serializes data to IPC pipe
# - IPC fork stage receives data via IPC pipe, processes in isolated process
class ThreadToIpcForkExample
  include Minigun::DSL

  attr_reader :results

  def initialize
    @results = []
    @results_file = "/tmp/minigun_thread_to_ipc_#{Process.pid}.txt"
  end

  def cleanup
    FileUtils.rm_f(@results_file)
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
        # Enrich data (threads have shared memory)
        enriched = item.merge(
          enriched_at: Time.now.to_i,
          thread_id: Thread.current.object_id
        )
        output << enriched
      end
    end

    # Consumer runs in IPC fork pool
    # Data is serialized via IPC pipes to isolated processes
    ipc_fork(2) do
      consumer :save do |item|
        puts "[Consumer:ipc_fork] Saving #{item[:id]} in forked process (PID #{Process.pid})"

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
  puts '=' * 80
  puts 'Example: Thread to IPC Fork Routing'
  puts '=' * 80
  puts ''

  example = ThreadToIpcForkExample.new
  begin
    example.run

    puts "\n#{'=' * 80}"
    puts 'Results:'
    puts "  Items processed: #{example.results.size}"
    puts '  Expected: 10'
    puts "  PIDs used: #{example.results.map { |r| r[:pid] }.uniq.sort.join(', ')}"

    success = example.results.size == 10 &&
              example.results.map { |r| r[:id] }.sort == (1..10).to_a

    puts "  Status: #{success ? '✓ SUCCESS' : '✗ FAILED'}"
    puts '=' * 80
    puts ''
    puts 'Key Points:'
    puts '  - Producer runs inline in master process'
    puts '  - Processor runs in thread pool (shared memory)'
    puts '  - Consumer runs in IPC fork pool (isolated processes)'
    puts '  - Data flows: master -> threads -> IPC pipes -> forks'
    puts '  - IPC ensures process isolation with serialization overhead'
    puts '=' * 80
  rescue NotImplementedError => e
    puts "\nForking not available on this platform: #{e.message}"
    puts '(This is expected on Windows)'
  ensure
    example.cleanup
  end
end
