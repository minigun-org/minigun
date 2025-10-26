#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

# Simple Nested Pipeline Example
# Demonstrates a pipeline within a pipeline
class NestedPipelineExample
  include Minigun::DSL

  attr_accessor :results

  def initialize
    @results = []
    @mutex = Mutex.new
  end

  pipeline do
    # Main pipeline contains a nested sub-pipeline
    producer :start do
      puts "[Main] Generating numbers 1-5"
      5.times { |i| emit(i + 1) }
    end

    # Nested sub-pipeline for transformation
    pipeline :transform_sub do
      # This pipeline receives items from parent
      processor :double do |num|
        result = num * 2
        puts "[SubPipeline] #{num} * 2 = #{result}"
        emit(result)
      end

      processor :add_ten do |num|
        result = num + 10
        puts "[SubPipeline] #{result - 10} + 10 = #{result}"
        emit(result)
      end
    end

    # Final consumer collects results
    consumer :collect do |num|
      puts "[Main] Collecting: #{num}"
      @mutex.synchronize { results << num }
    end
  end
end

if __FILE__ == $0
  puts "=== Nested Pipeline Example ===\n\n"
  puts "Flow: start → transform_sub (double → add_ten) → collect\n\n"

  example = NestedPipelineExample.new
  example.run

  puts "\n=== Results ===\n"
  puts "Collected: #{example.results.sort.inspect}"
  puts "Expected: [12, 14, 16, 18, 20]"

  success = example.results.sort == [12, 14, 16, 18, 20]
  puts success ? "✓ Success!" : "✗ Failed"
end

