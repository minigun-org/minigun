#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

# Example: Demand with Thread Pool
# Tests demand with concurrent processing
class DemandThreadedExample
  include Minigun::DSL

  attr_accessor :results, :thread_ids

  def initialize
    @results = []
    @thread_ids = []
    @mutex = Mutex.new
  end

  pipeline demand: true do
    producer :source do |output|
      100.times { |i| output << i }
    end

    # Process in thread pool with demand
    in_threads(4) do
      consumer :processor do |item, output|
        @mutex.synchronize { thread_ids << Thread.current.object_id }
        output << (item * 2)
      end
    end

    consumer :sink do |item|
      @mutex.synchronize { results << item }
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  puts "=== Demand with Thread Pool Example ===\n\n"
  puts "Demand works with concurrent processing in thread pools.\n\n"

  example = DemandThreadedExample.new
  example.run

  unique_threads = example.thread_ids.uniq.size

  puts "Results: #{example.results.size} items processed"
  puts "Unique threads used: #{unique_threads}"
  puts 'Expected: 100 items, up to 4 threads'

  success = example.results.size == 100
  puts success ? "\n✓ All items processed with threads!" : "\n✗ Item count mismatch"
end
