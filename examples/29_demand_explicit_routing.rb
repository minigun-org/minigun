#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

# Example: Demand with Explicit Routing
# Tests demand with output.to(:target) routing
class DemandExplicitRoutingExample
  include Minigun::DSL

  attr_accessor :high_values, :low_values

  def initialize
    @high_values = []
    @low_values = []
    @mutex = Mutex.new
  end

  pipeline demand: true do
    producer :source do |output|
      50.times { |i| output << i }
    end

    # Router decides destination based on value
    consumer :router, to: %i[high_path low_path] do |item, output|
      if item >= 25
        output.to(:high_path) << item
      else
        output.to(:low_path) << item
      end
    end

    consumer :high_path do |item|
      @mutex.synchronize { high_values << item }
    end

    consumer :low_path do |item|
      @mutex.synchronize { low_values << item }
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  puts "=== Demand Explicit Routing Example ===\n\n"
  puts 'Demand works with explicit routing via output.to(:target)'
  puts "Items >= 25 go to :high_path, others to :low_path\n\n"

  example = DemandExplicitRoutingExample.new
  example.run

  puts "High values: #{example.high_values.size} items (expected: 25)"
  puts "Low values: #{example.low_values.size} items (expected: 25)"

  success = example.high_values.size == 25 && example.low_values.size == 25
  puts success ? "\n✓ Routing with demand works!" : "\n✗ Routing mismatch"

  puts "\nHigh values sample: #{example.high_values.sort.first(5).inspect}..."
  puts "Low values sample: #{example.low_values.sort.first(5).inspect}..."
end
