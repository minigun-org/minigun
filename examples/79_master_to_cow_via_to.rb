#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

# Example: Master to COW Fork Routing (via output.to())
#
# Demonstrates explicit routing from master process to COW fork stages using output.to().
# This bypasses sequential routing and directly targets specific stages.
#
# Architecture:
# - Producer (inline) routes explicitly to COW fork stages via output.to(:stage_name)
# - COW fork stages receive items directly via COW-shared memory
# - Useful for conditional routing to different processing paths
class MasterToCowViaToExample
  include Minigun::DSL

  attr_reader :results_a, :results_b

  def initialize
    @results_a = []
    @results_b = []
    @results_a_file = "/tmp/minigun_cow_a_#{Process.pid}.txt"
    @results_b_file = "/tmp/minigun_cow_b_#{Process.pid}.txt"
  end

  def cleanup
    FileUtils.rm_f(@results_a_file)
    FileUtils.rm_f(@results_b_file)
  end

  pipeline do
    # Producer explicitly routes to specific COW fork stages
    producer :generate do |output|
      puts "[Producer] Generating 10 items with explicit routing (PID #{Process.pid})"

      10.times do |i|
        item = { id: i + 1, value: (i + 1) * 10 }

        # Explicit routing: route even IDs to :process_a, odd IDs to :process_b
        if item[:id].even?
          puts "  Routing #{item[:id]} to :process_a"
          output.to(:process_a) << item
        else
          puts "  Routing #{item[:id]} to :process_b"
          output.to(:process_b) << item
        end
      end
    end

    # COW fork stage A - receives even IDs
    cow_fork(2) do
      consumer :process_a do |item|
        pid = Process.pid
        puts "[ProcessA:cow_fork] Processing #{item[:id]} in ephemeral fork PID #{pid}"
        sleep 0.03

        # Write to temp file (fork-safe)
        File.open(@results_a_file, 'a') do |f|
          f.flock(File::LOCK_EX)
          f.puts "#{item[:id]}:#{pid}"
          f.flock(File::LOCK_UN)
        end
      end
    end

    # COW fork stage B - receives odd IDs
    cow_fork(2) do
      consumer :process_b do |item|
        pid = Process.pid
        puts "[ProcessB:cow_fork] Processing #{item[:id]} in ephemeral fork PID #{pid}"
        sleep 0.03

        # Write to temp file (fork-safe)
        File.open(@results_b_file, 'a') do |f|
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
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  puts '=' * 80
  puts 'Example: Master to COW Fork Routing (via output.to())'
  puts '=' * 80
  puts ''

  example = MasterToCowViaToExample.new
  begin
    example.run

    puts "\n#{'=' * 80}"
    puts 'Results:'
    puts "  ProcessA received: #{example.results_a.size} items (expected: 5 even IDs)"
    puts "  ProcessB received: #{example.results_b.size} items (expected: 5 odd IDs)"

    a_ids = example.results_a.map { |r| r[:id] }.sort
    b_ids = example.results_b.map { |r| r[:id] }.sort

    puts "  ProcessA IDs: #{a_ids.inspect}"
    puts "  ProcessB IDs: #{b_ids.inspect}"

    success = example.results_a.size == 5 &&
              example.results_b.size == 5 &&
              a_ids == [2, 4, 6, 8, 10] &&
              b_ids == [1, 3, 5, 7, 9]

    puts "  Status: #{success ? '✓ SUCCESS' : '✗ FAILED'}"
    puts '=' * 80
    puts ''
    puts 'Key Points:'
    puts '  - Producer uses output.to(:stage_name) for explicit routing'
    puts '  - COW fork stages receive items via COW-shared memory'
    puts '  - No input serialization overhead (COW advantage)'
    puts '  - Ephemeral forks (one per item)'
    puts '  - Useful for: content-based routing with large inputs'
    puts '  - COW optimal when: large data structures, read-only access'
    puts '=' * 80
  rescue NotImplementedError => e
    puts "\nForking not available on this platform: #{e.message}"
    puts '(This is expected on Windows)'
  ensure
    example.cleanup
  end
end
