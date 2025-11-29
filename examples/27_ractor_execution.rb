#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

# Demonstrates Ractor-based parallel execution with Ruby 4.0+ Ractor::Port API
#
# Requirements:
# - Ruby 4.0+ (uses Ractor::Port for communication)
# - Stage blocks must be "shareable" (no mutable captures)
#
# Ractors provide TRUE parallelism - each Ractor runs on its own OS thread
# without GIL restrictions. This is ideal for CPU-bound workloads.
#
# Key constraints:
# - Stage blocks must not capture instance variables or mutable state
# - Stage blocks should be pure functions (input -> output)
# - If block is not shareable, falls back to thread pool automatically
#
# Architecture:
# - Main Ractor creates a result_port (only main can receive from it)
# - Worker Ractors receive items via their default_port
# - Workers send results to the shared result_port
# - Main collects results from result_port
#
class RactorExample
  include Minigun::DSL

  pipeline do
    producer :generate do |output|
      10.times { |i| output << i }
    end

    # Ractors provide true parallelism (bypasses GIL)
    # Blocks inside in_ractors are automatically made shareable
    # The block must be a pure function - no captured state
    in_ractors(4) do
      processor :compute do |item, output|
        # CPU-intensive work benefits from true parallelism
        # Each Ractor can utilize a separate CPU core
        result = (1..1000).reduce(item.to_f) { |acc, _| Math.sqrt((acc**2) + 1) }
        output << { input: item, computed: result.round(4) }
      end
    end

    consumer :collect do |item|
      puts "Computed: #{item[:input]} -> #{item[:computed]}"
    end
  end
end

# Example with non-shareable block (demonstrates fallback)
class RactorFallbackExample
  include Minigun::DSL

  attr_reader :results

  def initialize
    @results = []
    @mutex = Mutex.new
  end

  pipeline do
    producer :generate do |output|
      5.times { |i| output << i }
    end

    # This block captures @mutex and @results - NOT shareable
    # Will automatically fall back to thread pool with a warning
    in_ractors(2) do
      processor :process do |item, output|
        output << (item**2)
      end
    end

    # This also captures instance state
    consumer :collect do |item|
      @mutex.synchronize { @results << item }
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  puts "Ruby version: #{RUBY_VERSION}"
  puts "Ractor::Port available: #{Minigun::Platform.ractors?}"
  puts

  if Minigun::Platform.ractors?
    puts '=== Running with Ractor parallelism ==='
    puts 'Using Ractor::Port API for true parallel execution'
  else
    puts '=== Running with thread fallback ==='
    puts 'Ractor::Port not available (requires Ruby 4.0+)'
    puts 'Falling back to thread pool execution'
  end
  puts

  puts '--- Pure function example (Ractor-compatible) ---'
  RactorExample.new.run
  puts

  puts '--- Non-shareable block example (falls back to threads) ---'
  example = RactorFallbackExample.new
  example.run
  puts "Processed #{example.results.size} items"
  puts "Results: #{example.results.sort.inspect}"
end
