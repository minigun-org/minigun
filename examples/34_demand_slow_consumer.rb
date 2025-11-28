#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

# Example: Demand with Slow Consumer
# Demonstrates backpressure preventing producer from overwhelming consumer
class DemandSlowConsumerExample
  include Minigun::DSL

  attr_accessor :results, :producer_done_at, :consumer_done_at

  def initialize
    @results = []
    @mutex = Mutex.new
    @producer_done_at = nil
    @consumer_done_at = nil
  end

  pipeline demand: true do
    # Fast producer - would normally overwhelm a slow consumer
    producer :fast_source do |output|
      30.times { |i| output << i }
      @producer_done_at = Time.now
    end

    # Slow consumer with small demand buffer
    # min_demand: 2, max_demand: 5 means we request 5 initially,
    # then request 3 more when we drop to 2 pending
    consumer :slow_sink, min_demand: 2, max_demand: 5 do |item|
      sleep 0.01 # Simulate slow processing
      @mutex.synchronize { results << item }
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  puts "=== Demand Slow Consumer Example ===\n\n"
  puts 'Backpressure prevents fast producer from overwhelming slow consumer.'
  puts 'Consumer settings: min_demand=2, max_demand=5'
  puts "Processing 30 items with 10ms delay each...\n\n"

  start = Time.now
  example = DemandSlowConsumerExample.new
  example.run
  duration = Time.now - start

  puts "Results: #{example.results.size} items processed"
  puts "Duration: #{duration.round(2)}s"
  puts "Expected: 30 items, ~0.3s minimum (30 * 10ms)"

  success = example.results.size == 30
  puts success ? '✓ All items processed!' : '✗ Item count mismatch'
end
