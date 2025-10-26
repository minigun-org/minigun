#!/usr/bin/env ruby
# frozen_string_literal: true

# Example 57: Threads + Batch + Process Per Batch
# Add process_per_batch to see if this breaks it

require_relative '../lib/minigun'

class ThreadsBatchProcessBatch
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

    consumer :save do |item|
      @mutex.synchronize { @results << item }
    end
  end
end

puts "Testing: threads + batch + process_per_batch + consumer"
pipeline = ThreadsBatchProcessBatch.new
pipeline.run
puts "Results: #{pipeline.results.size} items"
puts pipeline.results.size == 20 ? "✓ Works!" : "✗ Failed"

