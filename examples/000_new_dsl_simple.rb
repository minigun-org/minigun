#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

# Simple single-pipeline example demonstrating the new queue-based DSL
class SimpleDslExample
  include Minigun::DSL

  attr_accessor :results

  def initialize
    @results = []
    @mutex = Mutex.new
  end

  # Unnamed pipeline for single-pipeline cases
  pipeline do
    # Producer: generates items, receives only output queue
    producer :generate do |output|
      puts '[Producer] Generating numbers...'
      5.times do |i|
        num = i + 1
        puts "[Producer] Emitting: #{num}"
        output << num
      end
    end

    # Processor: transforms items, receives item and output queue
    processor :double do |num, output|
      doubled = num * 2
      puts "[Processor] #{num} * 2 = #{doubled}"
      output << doubled
    end

    # Consumer: terminal stage, receives only the item
    consumer :collect do |num|
      puts "[Consumer] Storing: #{num}"
      @mutex.synchronize { results << num }
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  puts "=== Simple Queue-Based DSL Example ===\n\n"

  example = SimpleDslExample.new
  example.run

  puts "\n=== Final Results ===\n"
  puts "Collected: #{example.results.sort.inspect}"
  puts 'Expected: [2, 4, 6, 8, 10]'
  puts example.results.sort == [2, 4, 6, 8, 10] ? '✓ Success!' : '✗ Failed'
end
