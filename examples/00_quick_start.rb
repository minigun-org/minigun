#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

# Quick Start Example
# The simplest possible Minigun pipeline
class QuickStartExample
  include Minigun::DSL

  attr_accessor :results

  def initialize
    @results = []
    @mutex = Mutex.new
  end

  pipeline do
    # Step 1: Generate items
    producer :generate do |output|
      10.times { |i| output << i }
    end

    # Step 2: Transform items
    processor :transform do |number, output|
      output << number * 2
    end

    # Step 3: Collect results
    consumer :collect do |item|
      @mutex.synchronize { results << item }
    end
  end
end

if __FILE__ == $0
  puts "=== Quick Start Example ===\n\n"
  puts "This is the simplest Minigun pipeline:"
  puts "  Producer (generate) → Processor (transform) → Consumer (collect)\n\n"

  example = QuickStartExample.new
  example.run

  puts "\n=== Results ===\n"
  puts "Input:  0, 1, 2, 3, 4, 5, 6, 7, 8, 9"
  puts "Output: #{example.results.sort.join(', ')}"
  puts "\nAll values doubled: #{example.results.sort == [0, 2, 4, 6, 8, 10, 12, 14, 16, 18] ? '✓' : '✗'}"
  puts "\n✓ Quick start complete!"
  puts "\nNext steps:"
  puts "  • Try 13_configuration.rb to learn about configuration options"
  puts "  • Try 11_hooks_example.rb to learn about lifecycle hooks"
  puts "  • Try 02_diamond_pattern.rb to learn about routing"
end

