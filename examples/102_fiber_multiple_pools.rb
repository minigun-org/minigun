#!/usr/bin/env ruby
# frozen_string_literal: true

# Example 102: Multiple Fiber Pools
#
# Demonstrates using multiple fiber pools with different sizes for different stages

require_relative '../lib/minigun'

puts '=' * 60
puts 'Multiple Fiber Pools'
puts '=' * 60

unless Minigun::Platform.async?
  puts "\n⚠️  The 'async' gem is not installed."
  exit 1
end

# Pipeline using multiple fiber pools with different sizes for different stages
class MultipleFiberPools
  include Minigun::DSL

  attr_reader :results

  def initialize
    @results = []
    @mutex = Mutex.new
  end

  pipeline do
    produce_each :items, (1..30).to_a

    # First pool: high concurrency for fast operations
    in_fibers(10) do
      processor :validate do |item, output|
        sleep 0.005 # Quick validation
        output << { value: item, valid: item.positive? }
      end
    end

    # Second pool: lower concurrency for heavier operations
    in_fibers(3) do
      processor :heavy_transform do |item, output|
        sleep 0.02 # Heavier processing
        item[:computed] = item[:value]**2
        output << item
      end
    end

    # Third pool: medium concurrency for I/O
    in_fibers(5) do
      processor :persist do |item, output|
        sleep 0.01 # Simulate DB write
        item[:persisted] = true
        output << item
      end
    end

    consumer :collect do |item|
      @mutex.synchronize { @results << item }
    end
  end
end

start_time = Time.now
pipeline = MultipleFiberPools.new
pipeline.run
elapsed = Time.now - start_time

puts "\nResults:"
puts "  Processed: #{pipeline.results.size} items"
puts "  All valid: #{pipeline.results.all? { |r| r[:valid] }}"
puts "  All computed: #{pipeline.results.all? { |r| r[:computed] }}"
puts "  All persisted: #{pipeline.results.all? { |r| r[:persisted] }}"
puts "  Sample: #{pipeline.results.first}"
puts "  Elapsed: #{elapsed.round(3)}s"
puts "\n✓ Multiple fiber pools with different concurrency levels"
