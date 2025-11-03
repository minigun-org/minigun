#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

# Example: COW Fork Fan-Out Pattern
#
# Demonstrates one COW fork stage routing to multiple downstream COW fork stages.
# Shows cross-boundary routing with fan-out topology using ephemeral forks.
#
# Architecture:
# - Producer -> COW Stage (splitter) -> [COW Stage A, COW Stage B, COW Stage C]
# - Splitter routes items to different stages based on content
# - All stages use ephemeral COW forks
# - COW-shared inputs, IPC outputs at each stage

class CowFanOutExample
  include Minigun::DSL

  attr_reader :results_a, :results_b, :results_c

  def initialize
    @results_a = []
    @results_b = []
    @results_c = []
    @results_a_file = "/tmp/minigun_cow_fan_out_a_#{Process.pid}.txt"
    @results_b_file = "/tmp/minigun_cow_fan_out_b_#{Process.pid}.txt"
    @results_c_file = "/tmp/minigun_cow_fan_out_c_#{Process.pid}.txt"
  end

  def cleanup
    File.unlink(@results_a_file) if File.exist?(@results_a_file)
    File.unlink(@results_b_file) if File.exist?(@results_b_file)
    File.unlink(@results_c_file) if File.exist?(@results_c_file)
  end

  pipeline do
    # Producer generates data
    producer :generate do |output|
      puts "[Producer] Generating 12 items (PID #{Process.pid})"
      12.times do |i|
        output << { id: i + 1, value: i + 1 }
      end
    end

    # Splitter stage in COW fork - routes to different stages
    cow_fork(2) do
      processor :splitter do |item, output|
        pid = Process.pid
        puts "[Splitter:cow_fork] Routing #{item[:id]} in ephemeral fork PID #{pid}"

        # Route based on modulo: 0->A, 1->B, 2->C
        case item[:id] % 3
        when 0
          output.to(:process_a) << item.merge(routed_to: 'A', splitter_pid: pid)
        when 1
          output.to(:process_b) << item.merge(routed_to: 'B', splitter_pid: pid)
        when 2
          output.to(:process_c) << item.merge(routed_to: 'C', splitter_pid: pid)
        end
      end
    end

    # Three COW fork consumer stages (fan-out targets)
    cow_fork(2) do
      consumer :process_a do |item|
        pid = Process.pid
        puts "[ProcessA:cow_fork] Processing #{item[:id]} in ephemeral fork PID #{pid}"
        sleep 0.03

        File.open(@results_a_file, 'a') do |f|
          f.flock(File::LOCK_EX)
          f.puts "#{item[:id]}:#{pid}"
          f.flock(File::LOCK_UN)
        end
      end
    end

    cow_fork(2) do
      consumer :process_b do |item|
        pid = Process.pid
        puts "[ProcessB:cow_fork] Processing #{item[:id]} in ephemeral fork PID #{pid}"
        sleep 0.03

        File.open(@results_b_file, 'a') do |f|
          f.flock(File::LOCK_EX)
          f.puts "#{item[:id]}:#{pid}"
          f.flock(File::LOCK_UN)
        end
      end
    end

    cow_fork(2) do
      consumer :process_c do |item|
        pid = Process.pid
        puts "[ProcessC:cow_fork] Processing #{item[:id]} in ephemeral fork PID #{pid}"
        sleep 0.03

        File.open(@results_c_file, 'a') do |f|
          f.flock(File::LOCK_EX)
          f.puts "#{item[:id]}:#{pid}"
          f.flock(File::LOCK_UN)
        end
      end
    end

    after_run do
      # Read results from temp files
      if File.exist?(@results_a_file)
        @results_a = File.readlines(@results_a_file).map do |line|
          id, pid = line.strip.split(':')
          { id: id.to_i, pid: pid.to_i }
        end
      end

      if File.exist?(@results_b_file)
        @results_b = File.readlines(@results_b_file).map do |line|
          id, pid = line.strip.split(':')
          { id: id.to_i, pid: pid.to_i }
        end
      end

      if File.exist?(@results_c_file)
        @results_c = File.readlines(@results_c_file).map do |line|
          id, pid = line.strip.split(':')
          { id: id.to_i, pid: pid.to_i }
        end
      end
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  puts "=" * 80
  puts "Example: COW Fork Fan-Out Pattern"
  puts "=" * 80
  puts ""

  example = CowFanOutExample.new
  begin
    example.run

    puts "\n" + "=" * 80
    puts "Results:"
    puts "  ProcessA received: #{example.results_a.size} items (expected: 4)"
    puts "  ProcessB received: #{example.results_b.size} items (expected: 4)"
    puts "  ProcessC received: #{example.results_c.size} items (expected: 4)"

    a_ids = example.results_a.map { |r| r[:id] }.sort
    b_ids = example.results_b.map { |r| r[:id] }.sort
    c_ids = example.results_c.map { |r| r[:id] }.sort

    puts "  ProcessA IDs: #{a_ids.inspect}"
    puts "  ProcessB IDs: #{b_ids.inspect}"
    puts "  ProcessC IDs: #{c_ids.inspect}"

    success = example.results_a.size == 4 &&
              example.results_b.size == 4 &&
              example.results_c.size == 4 &&
              a_ids == [3, 6, 9, 12] &&
              b_ids == [1, 4, 7, 10] &&
              c_ids == [2, 5, 8, 11]

    puts "  Status: #{success ? '✓ SUCCESS' : '✗ FAILED'}"
    puts "=" * 80
    puts ""
    puts "Key Points:"
    puts "  - Fan-out from COW splitter to 3 COW consumers"
    puts "  - All stages use ephemeral forks (one per item)"
    puts "  - Splitter makes routing decisions in COW fork"
    puts "  - No input serialization (COW-shared)"
    puts "  - Output serialization for routing back to parent"
    puts "  - Many short-lived processes created"
    puts "  - Useful for: CPU-intensive partitioning with large inputs"
    puts "=" * 80
  rescue NotImplementedError => e
    puts "\nForking not available on this platform: #{e.message}"
    puts "(This is expected on Windows)"
  ensure
    example.cleanup
  end
end
