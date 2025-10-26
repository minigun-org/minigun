#!/usr/bin/env ruby
# frozen_string_literal: true

# Example 53: Batch + Named Context
# Test batching with named contexts

require_relative '../lib/minigun'

class BatchWithNamed
  include Minigun::DSL

  attr_reader :results

  def initialize
    @results = []
    @mutex = Mutex.new
  end

  pipeline do
    execution_context :processor_pool, :threads, 3

    producer :gen do
      30.times { |i| emit(i) }
    end

    processor :prep, execution_context: :processor_pool do |item|
      emit(item + 1)
    end

    batch 5

    processor :process_batch do |batch|
      batch.each { |item| emit(item * 2) }
    end

    consumer :save do |item|
      @mutex.synchronize { @results << item }
    end
  end
end

puts "Testing: batch + named context"
pipeline = BatchWithNamed.new
pipeline.run
puts "Results: #{pipeline.results.size} items"
puts "✓ Batch + named works" if pipeline.results.size == 30

