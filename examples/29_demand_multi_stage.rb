#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

# Example: Multi-Stage Demand Pipeline
# Demand propagates through multiple processing stages
class DemandMultiStageExample
  include Minigun::DSL

  attr_accessor :results

  def initialize
    @results = []
    @mutex = Mutex.new
  end

  pipeline demand: true do
    # Fast producer
    producer :source do |output|
      50.times { |i| output << i }
    end

    # Stage 1: Filter even numbers
    consumer :filter do |item, output|
      output << item if item.even?
    end

    # Stage 2: Transform
    consumer :transform do |item, output|
      output << (item * 10)
    end

    # Stage 3: Enrich
    consumer :enrich do |item, output|
      output << { value: item, label: "item_#{item}" }
    end

    # Final consumer
    consumer :sink do |item|
      @mutex.synchronize { results << item }
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  puts "=== Multi-Stage Demand Example ===\n\n"
  puts 'Demand propagates through the entire pipeline:'
  puts "  source → filter → transform → enrich → sink\n\n"

  example = DemandMultiStageExample.new
  example.run

  puts "Results: #{example.results.size} items"
  puts 'Expected: 25 (even numbers 0-48, filtered then transformed)'

  expected_count = 25 # 0, 2, 4, ..., 48 = 25 even numbers
  puts example.results.size == expected_count ? '✓ Correct count!' : '✗ Count mismatch'

  puts "\nSample results:"
  example.results.sort_by { |r| r[:value] }.first(3).each do |r|
    puts "  #{r.inspect}"
  end
end
