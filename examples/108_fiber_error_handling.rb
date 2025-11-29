#!/usr/bin/env ruby
# frozen_string_literal: true

# Example 108: Fiber Error Handling
#
# Demonstrates how errors in fibers are isolated and don't crash other fibers

require_relative '../lib/minigun'

puts '=' * 60
puts 'Fiber Error Handling'
puts '=' * 60

unless Minigun::Platform.fibers?
  puts "\n⚠️  The 'async' gem is not installed."
  exit 1
end

# Pipeline demonstrating isolated error handling in fibers
class FiberErrorHandling
  include Minigun::DSL

  attr_reader :results, :errors_encountered

  def initialize
    @results = []
    @errors_encountered = []
    @mutex = Mutex.new
  end

  pipeline do
    produce_each :items, (1..20).to_a

    in_fibers(5) do
      processor :risky_operation do |item, output|
        # Simulate errors on certain items
        if item % 5 == 0
          @mutex.synchronize { @errors_encountered << item }
          raise "Simulated error on item #{item}"
        end

        sleep 0.01
        output << { value: item, processed: true }
      end
    end

    # Continue processing survivors
    in_fibers(3) do
      processor :post_process do |item, output|
        item[:post_processed] = true
        output << item
      end
    end

    consumer :collect do |item|
      @mutex.synchronize { @results << item }
    end
  end
end

start_time = Time.now
pipeline = FiberErrorHandling.new
pipeline.run
elapsed = Time.now - start_time

puts "\nResults:"
puts "  Successfully processed: #{pipeline.results.size} items"
puts "  Errors encountered: #{pipeline.errors_encountered.size} items"
puts "  Error items: #{pipeline.errors_encountered.join(', ')}"
puts "  Successful items: #{pipeline.results.map { |r| r[:value] }.sort.join(', ')}"
puts "  All post-processed: #{pipeline.results.all? { |r| r[:post_processed] }}"
puts "  Elapsed: #{elapsed.round(3)}s"
puts "\n✓ Errors are isolated per fiber"
puts '✓ Other fibers continue processing'
puts '✓ Pipeline completes despite errors'
