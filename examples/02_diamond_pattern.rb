#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

# Example 2: Diamond Pattern
# One producer splits to multiple processors, then merges back
class DiamondPipeline
  include Minigun::DSL

  max_threads 3

  attr_accessor :results_a, :results_b, :merged

  def initialize
    @results_a = []
    @results_b = []
    @merged = []
    @mutex = Mutex.new
  end

  pipeline do
    # Producer splits to two processors
    producer :source, to: %i[path_a path_b] do |output|
      5.times { |i| output << (i + 1) }
    end

    # Path A: multiply by 2
    processor :path_a, to: :merge do |num, output|
      result = num * 2
      @mutex.synchronize { results_a << result }
      output << result
    end

    # Path B: multiply by 3
    processor :path_b, to: :merge do |num, output|
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
  pipeline = DiamondPipeline.new
  pipeline.run

  puts 'Diamond Pipeline Results:'
  puts 'Input: 1, 2, 3, 4, 5'
  puts "Path A (x2): #{pipeline.results_a.sort.inspect}"
  puts "Path B (x3): #{pipeline.results_b.sort.inspect}"
  puts "Merged: #{pipeline.merged.sort.inspect}"
  puts "Total items: #{pipeline.merged.size}"
end
