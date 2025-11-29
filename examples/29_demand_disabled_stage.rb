#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

# Example: Selective Demand Disabling
# Shows how to disable demand for specific stages
class DemandDisabledStageExample
  include Minigun::DSL

  attr_accessor :results

  def initialize
    @results = []
    @mutex = Mutex.new
  end

  pipeline demand: true do
    producer :source do |output|
      50.times { |i| output << i }
    end

    # This stage has demand disabled - won't wait for downstream demand
    # Useful for stages that must emit immediately (e.g., logging, metrics)
    consumer :passthrough, demand_mode: :disabled do |item, output|
      output << item
    end

    # Normal demand-aware consumer
    consumer :sink do |item|
      @mutex.synchronize { results << item }
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  puts "=== Demand Disabled Stage Example ===\n\n"
  puts 'Individual stages can opt out of demand tracking.'
  puts "The :passthrough stage has demand_mode: :disabled\n\n"

  example = DemandDisabledStageExample.new
  example.run

  puts "Results: #{example.results.size} items processed"
  puts 'Expected: 50'
  puts example.results.size == 50 ? '✓ All items processed!' : '✗ Item count mismatch'
end
