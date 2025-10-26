#!/usr/bin/env ruby
# frozen_string_literal: true

# Example 58: Add final threads block
# Test if threads block after process_per_batch causes issues

require_relative '../lib/minigun'

class WithFinalThreads
  include Minigun::DSL

  attr_reader :results

  def initialize
    @results = []
    @mutex = Mutex.new
  end

  pipeline do
    producer :gen do
      20.times { |i| emit(i) }
    end

    threads(3) do
      processor :work do |item|
        emit(item * 2)
      end
    end

    batch 5

    process_per_batch(max: 2) do
      processor :process_batch do |batch|
        batch.each { |item| emit(item + 100) }
      end
    end

    threads(2) do
      consumer :save do |item|
        @mutex.synchronize { @results << item }
      end
    end
  end
end

puts "Testing: threads + batch + process_per_batch + threads(consumer)"
pipeline = WithFinalThreads.new
pipeline.run
puts "Results: #{pipeline.results.size} items"
puts pipeline.results.size == 20 ? "✓ Works!" : "✗ Failed"

