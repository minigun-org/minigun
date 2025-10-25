#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

# Reroute Stage Example
# Demonstrates using reroute_stage to modify pipeline routing
class RerouteBaseExample
  include Minigun::DSL

  attr_accessor :results

  def initialize
    @results = []
  end

  producer :generate do
    puts "[Producer] Generating 5 items"
    5.times { |i| emit(i + 1) }
  end

  processor :double do |num|
    result = num * 2
    puts "[Double] #{num} * 2 = #{result}"
    emit(result)
  end

  consumer :collect do |num|
    puts "[Collect] Received: #{num}"
    @results << num
  end
end

# Child class that reroutes to skip the doubling
class RerouteSkipExample < RerouteBaseExample
  # Override routing to skip the double stage
  reroute_stage :generate, to: :collect
end

# Child class that inserts a new stage
class RerouteInsertExample < RerouteBaseExample
  processor :triple do |num|
    result = num * 3
    puts "[Triple] #{num} * 3 = #{result}"
    emit(result)
  end

  # Reroute to insert triple between double and collect
  reroute_stage :double, to: :triple
  reroute_stage :triple, to: :collect
end

if __FILE__ == $0
  puts "=== Reroute Stage Example ===\n\n"

  puts "--- Base Pipeline ---"
  puts "Flow: generate -> double -> collect"
  base = RerouteBaseExample.new
  base.run
  puts "Results: #{base.results.inspect}"
  puts "Expected: [2, 4, 6, 8, 10]"
  puts base.results == [2, 4, 6, 8, 10] ? "✓ Pass" : "✗ Fail"

  puts "\n--- Skip Stage (Reroute) ---"
  puts "Flow: generate -> collect (skips double)"
  skip = RerouteSkipExample.new
  skip.run
  puts "Results: #{skip.results.inspect}"
  puts "Expected: [1, 2, 3, 4, 5]"
  puts skip.results == [1, 2, 3, 4, 5] ? "✓ Pass" : "✗ Fail"

  puts "\n--- Insert Stage (Reroute) ---"
  puts "Flow: generate -> double -> triple -> collect"
  insert = RerouteInsertExample.new
  insert.run
  puts "Results: #{insert.results.inspect}"
  puts "Expected: [6, 12, 18, 24, 30] (double then triple)"
  puts insert.results == [6, 12, 18, 24, 30] ? "✓ Pass" : "✗ Fail"

  puts "\n=== Key Concepts ==="
  puts "• reroute_stage modifies the DAG routing for a stage"
  puts "• Useful for inheritance: child classes can change parent's routing"
  puts "• Can skip stages, insert stages, or create new paths"
  puts "• Works with the explicit routing system"
  puts "\n✓ Reroute stage complete!"
end

