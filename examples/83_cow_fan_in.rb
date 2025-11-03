#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

# Example: COW Fork Fan-In Pattern
#
# Demonstrates multiple producers routing to a single COW fork aggregator stage.
# Shows cross-boundary routing with fan-in topology using ephemeral forks.
#
# Architecture:
# - [Producer A, Producer B, Producer C] -> COW Aggregator
# - Multiple producers feed into single COW fork stage
# - Aggregator receives items from all producers
# - COW-shared inputs, no output (terminal consumer)

class CowFanInExample
  include Minigun::DSL

  attr_reader :results

  def initialize
    @results = []
    @results_file = "/tmp/minigun_cow_fan_in_#{Process.pid}.txt"
  end

  def cleanup
    File.unlink(@results_file) if File.exist?(@results_file)
  end

  pipeline do
    # Three producers generating data in parallel
    producer :producer_a do |output|
      puts "[ProducerA] Generating items with prefix A"
      4.times do |i|
        output << { id: "A#{i + 1}", value: i + 1, source: 'A' }
      end
    end

    producer :producer_b do |output|
      puts "[ProducerB] Generating items with prefix B"
      4.times do |i|
        output << { id: "B#{i + 1}", value: i + 1, source: 'B' }
      end
    end

    producer :producer_c do |output|
      puts "[ProducerC] Generating items with prefix C"
      4.times do |i|
        output << { id: "C#{i + 1}", value: i + 1, source: 'C' }
      end
    end

    # Aggregator stage - receives from all three producers
    # Uses COW fork to process merged stream
    cow_fork(2) do
      consumer :aggregator do |item|
        pid = Process.pid
        puts "[Aggregator:cow_fork] Processing #{item[:id]} from #{item[:source]} in ephemeral fork PID #{pid}"
        sleep 0.03

        # Item is COW-shared (no serialization overhead)
        File.open(@results_file, 'a') do |f|
          f.flock(File::LOCK_EX)
          f.puts "#{item[:id]}:#{item[:source]}:#{pid}"
          f.flock(File::LOCK_UN)
        end
      end
    end

    after_run do
      # Read results from temp file
      if File.exist?(@results_file)
        @results = File.readlines(@results_file).map do |line|
          id, source, pid = line.strip.split(':')
          { id: id, source: source, pid: pid.to_i }
        end
      end
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  puts "=" * 80
  puts "Example: COW Fork Fan-In Pattern"
  puts "=" * 80
  puts ""

  example = CowFanInExample.new
  begin
    example.run

    puts "\n" + "=" * 80
    puts "Results:"
    puts "  Total items processed: #{example.results.size} (expected: 12)"

    by_source = example.results.group_by { |r| r[:source] }
    puts "  From ProducerA: #{by_source['A']&.size || 0} items"
    puts "  From ProducerB: #{by_source['B']&.size || 0} items"
    puts "  From ProducerC: #{by_source['C']&.size || 0} items"

    worker_pids = example.results.map { |r| r[:pid] }.uniq.sort
    puts "  Fork PIDs used: #{worker_pids.size} (ephemeral forks)"

    success = example.results.size == 12 &&
              by_source['A']&.size == 4 &&
              by_source['B']&.size == 4 &&
              by_source['C']&.size == 4

    puts "  Status: #{success ? '✓ SUCCESS' : '✗ FAILED'}"
    puts "=" * 80
    puts ""
    puts "Key Points:"
    puts "  - Fan-in from 3 producers to 1 COW aggregator"
    puts "  - All producers run in master process (inline)"
    puts "  - Aggregator receives merged stream via single input queue"
    puts "  - COW forks handle items (one fork per item)"
    puts "  - No input serialization (COW-shared)"
    puts "  - Terminal consumer (no output serialization)"
    puts "  - Useful for: CPU-intensive aggregation with large inputs"
    puts "  - Processing order is non-deterministic (interleaved)"
    puts "=" * 80
  rescue NotImplementedError => e
    puts "\nForking not available on this platform: #{e.message}"
    puts "(This is expected on Windows)"
  ensure
    example.cleanup
  end
end
