#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

# Custom router stage that uses yield with to: parameter for dynamic routing
class ParityRouter < Minigun::ConsumerStage
  def call(item)
    if item.even?
      # Route even numbers to even_processor
      yield(item, to: :even_processor)
    else
      # Route odd numbers to odd_processor
      yield(item, to: :odd_processor)
    end
  end
end

# Custom processor for even numbers
class EvenProcessor < Minigun::ConsumerStage
  def call(item)
    # Double even numbers
    yield(item * 2)
  end
end

# Custom processor for odd numbers
class OddProcessor < Minigun::ConsumerStage
  def call(item)
    # Triple odd numbers
    yield(item * 3)
  end
end

# Example demonstrating yield with dynamic routing
class YieldRoutingExample
  include Minigun::DSL

  attr_reader :even_results, :odd_results

  def initialize
    @even_results = []
    @odd_results = []
    @mutex = Mutex.new
  end

  pipeline do
    # Generate numbers 0-9
    producer :generate do |output|
      10.times { |i| output << i }
    end

    # Route numbers based on parity using yield(item, to: :stage_name)
    custom_stage(ParityRouter, :router, from: :generate)

    # Process even and odd numbers separately
    custom_stage(EvenProcessor, :even_processor)
    custom_stage(OddProcessor, :odd_processor)

    # Collect results from each processor
    consumer :collect_even, from: :even_processor do |item|
      @mutex.synchronize { @even_results << item }
    end

    consumer :collect_odd, from: :odd_processor do |item|
      @mutex.synchronize { @odd_results << item }
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  puts "=== Yield with Dynamic Routing Example ===\n\n"
  puts 'This example demonstrates using yield with the to: parameter'
  puts 'to dynamically route items to specific stages by name.'
  puts ''
  puts 'The router inspects each number and routes it to either'
  puts 'the even_processor or odd_processor based on parity.'
  puts ''
  puts "Key feature: yield(item, to: :stage_name)\n\n"

  example = YieldRoutingExample.new
  example.run

  puts "=== Results ===\n"
  puts "Input numbers: 0-9"
  puts "Even numbers (doubled): #{example.even_results.sort.join(', ')}"
  puts "Odd numbers (tripled): #{example.odd_results.sort.join(', ')}"

  expected_even = [0, 4, 8, 12, 16]  # 0*2, 2*2, 4*2, 6*2, 8*2
  expected_odd = [3, 9, 15, 21, 27]  # 1*3, 3*3, 5*3, 7*3, 9*3

  puts ''
  puts "Even results correct: #{example.even_results.sort == expected_even ? '✓' : '✗'}"
  puts "Odd results correct: #{example.odd_results.sort == expected_odd ? '✓' : '✗'}"
  puts "\n✓ Yield routing example complete!"
  puts ''
  puts 'Benefits of yield with dynamic routing:'
  puts '  • Natural Ruby syntax for routing logic'
  puts '  • Type-safe stage name references'
  puts '  • Clear intent in routing decisions'
  puts '  • Stages with only dynamic inputs work correctly'
end

