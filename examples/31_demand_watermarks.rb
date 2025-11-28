#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

# Example: Custom Demand Watermarks
# Shows how min_demand and max_demand control batch sizes
class DemandWatermarksExample
  include Minigun::DSL

  attr_accessor :results, :batch_sizes

  def initialize
    @results = []
    @batch_sizes = []
    @current_batch = 0
    @mutex = Mutex.new
  end

  pipeline demand: true do
    producer :source do |output|
      200.times { |i| output << i }
    end

    # Custom watermarks: request more when below 10, request up to 50
    # This creates batches of approximately (50 - 10) = 40 items
    consumer :processor, min_demand: 10, max_demand: 50 do |item, output|
      output << item * 2
    end

    consumer :sink do |item|
      @mutex.synchronize { results << item }
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  puts "=== Demand Watermarks Example ===\n\n"
  puts 'Custom min_demand and max_demand control demand replenishment:'
  puts '  - min_demand: 10 (request more when pending drops below this)'
  puts "  - max_demand: 50 (request this many items at a time)\n\n"

  example = DemandWatermarksExample.new
  example.run

  puts "Results: #{example.results.size} items processed"
  puts "Expected: 200 (doubled values)"
  puts example.results.size == 200 ? '✓ All items processed!' : '✗ Item count mismatch'
  puts "Sample values: #{example.results.sort.first(5).inspect}..."
end
