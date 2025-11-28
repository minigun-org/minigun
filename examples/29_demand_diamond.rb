#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

# Example: Demand with Diamond Pattern
# Tests demand propagation through fan-out and fan-in
class DemandDiamondExample
  include Minigun::DSL

  attr_accessor :results_a, :results_b, :merged

  def initialize
    @results_a = []
    @results_b = []
    @merged = []
    @mutex = Mutex.new
  end

  pipeline demand: true do
    # Producer fans out to two paths
    producer :source, to: %i[path_a path_b] do |output|
      20.times { |i| output << i }
    end

    # Path A: multiply by 2
    consumer :path_a, to: :merge do |num, output|
      result = num * 2
      @mutex.synchronize { results_a << result }
      output << result
    end

    # Path B: multiply by 3
    consumer :path_b, to: :merge do |num, output|
      result = num * 3
      @mutex.synchronize { results_b << result }
      output << result
    end

    # Merge results from both paths
    consumer :merge do |num|
      @mutex.synchronize { merged << num }
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  puts "=== Demand Diamond Pattern Example ===\n\n"
  puts 'Demand works with fan-out/fan-in topologies:'
  puts '  source → path_a → merge'
  puts "         ↘ path_b ↗\n\n"

  example = DemandDiamondExample.new
  example.run

  puts "Path A results: #{example.results_a.size} items"
  puts "Path B results: #{example.results_b.size} items"
  puts "Merged results: #{example.merged.size} items"
  puts "\nExpected: 20 items each path, 40 merged"

  success = example.results_a.size == 20 &&
            example.results_b.size == 20 &&
            example.merged.size == 40

  puts success ? '✓ All items processed correctly!' : '✗ Item count mismatch'

  puts "\nPath A (x2): #{example.results_a.sort.first(5).inspect}..."
  puts "Path B (x3): #{example.results_b.sort.first(5).inspect}..."
end
