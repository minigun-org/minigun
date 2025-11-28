#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

# Example: Demand with Accumulator Stage
# Tests demand propagation through batch accumulation
class DemandAccumulatorExample
  include Minigun::DSL

  attr_accessor :batches, :total_items

  def initialize
    @batches = []
    @total_items = 0
    @mutex = Mutex.new
  end

  pipeline demand: true do
    producer :source do |output|
      100.times { |i| output << i }
    end

    # Accumulator batches items before passing downstream
    accumulator :batcher, max_size: 10

    # Consumer receives batches
    consumer :sink do |batch|
      @mutex.synchronize do
        batches << batch.size
        @total_items += batch.size
      end
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  puts "=== Demand with Accumulator Example ===\n\n"
  puts 'Accumulator batches items before passing to downstream consumer.'
  puts "Batch size: 10\n\n"

  example = DemandAccumulatorExample.new
  example.run

  puts "Total items: #{example.total_items}"
  puts "Number of batches: #{example.batches.size}"
  puts "Batch sizes: #{example.batches.inspect}"
  puts "\nExpected: 100 items in 10 batches of 10"

  success = example.total_items == 100 && example.batches.size == 10
  puts success ? '✓ All items batched correctly!' : '✗ Batching mismatch'
end
