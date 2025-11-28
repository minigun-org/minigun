#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

# Example: Basic Demand-Based Backpressure
# Demonstrates pull-based flow control where consumers request items from producers
class DemandBasicExample
  include Minigun::DSL

  attr_accessor :results

  def initialize
    @results = []
    @mutex = Mutex.new
  end

  # Enable demand mode for this pipeline
  pipeline demand: true do
    # Producer emits items - will be gated by downstream demand
    producer :source do |output|
      100.times { |i| output << i }
    end

    # Consumer with default demand settings (min_demand: 500, max_demand: 1000)
    # Since we only emit 100 items, this will work smoothly
    consumer :sink do |item|
      @mutex.synchronize { results << item }
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  puts "=== Basic Demand Example ===\n\n"
  puts 'Demand-based backpressure ensures producers wait for consumer demand.'
  puts "This prevents fast producers from overwhelming slow consumers.\n\n"

  example = DemandBasicExample.new
  example.run

  puts "Results: #{example.results.size} items processed"
  puts 'Expected: 100'
  puts example.results.size == 100 ? '✓ All items processed!' : '✗ Item count mismatch'
end
