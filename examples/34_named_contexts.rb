#!/usr/bin/env ruby
# frozen_string_literal: true

# Example 34: Named Execution Contexts
#
# Demonstrates defining named contexts and assigning them to specific stages

require_relative '../lib/minigun'

puts "=" * 60
puts "Named Execution Contexts"
puts "=" * 60

class DataPipeline
  include Minigun::DSL

  attr_reader :results

  def initialize
    @results = []
    @mutex = Mutex.new
  end

  pipeline do
    # Define named execution contexts upfront
    execution_context :io_workers, :threads, 50
    execution_context :cpu_workers, :processes, 4
    execution_context :fast_lane, :threads, 100

    producer :generate do
      100.times { |i| emit(i) }
    end

    # Assign specific context to stage
    processor :fetch, execution_context: :io_workers do |item|
      # I/O work using io_workers pool
      emit({ id: item, data: "fetched-#{item}" })
    end

    # Different stage, different context
    processor :compute, execution_context: :cpu_workers do |item|
      # CPU work using cpu_workers pool
      emit({ id: item[:id], computed: item[:data].upcase })
    end

    # Fast lane for final processing
    processor :validate, execution_context: :fast_lane do |item|
      emit(item[:computed])
    end

    consumer :save do |item|
      @mutex.synchronize { @results << item }
    end
  end
end

pipeline = DataPipeline.new
pipeline.run

puts "\nResults:"
puts "  Processed: #{pipeline.results.size} items"
puts "\n✓ Named contexts assigned to specific stages"
puts "✓ io_workers (50 threads) for fetch"
puts "✓ cpu_workers (4 processes) for compute"
puts "✓ fast_lane (100 threads) for validate"
puts "✓ Flexible, declarative stage assignment"

puts "\n" + "=" * 60
puts "Example 2: Mixed Named and Block Contexts"
puts "=" * 60

class MixedPipeline
  include Minigun::DSL

  attr_reader :count

  def initialize
    @count = 0
    @mutex = Mutex.new
  end

  pipeline do
    # Named context for specific stages
    execution_context :heavy_compute, :processes, 8

    producer :gen do
      50.times { |i| emit(i) }
    end

    # Use block context for some stages
    threads(20) do
      processor :download do |item|
        emit(item * 2)
      end

      processor :parse do |item|
        emit({ value: item })
      end
    end

    # Use named context for specific heavy work
    processor :heavy_work, execution_context: :heavy_compute do |item|
      # CPU-intensive work in isolated process
      emit(item[:value] ** 2)
    end

    # Back to default for final stage
    consumer :save do |result|
      @mutex.synchronize { @count += 1 }
    end
  end
end

pipeline = MixedPipeline.new
pipeline.run

puts "\nResults:"
puts "  Processed: #{pipeline.count} items"
puts "\n✓ Block contexts (threads) for I/O stages"
puts "✓ Named context (heavy_compute) for CPU stage"
puts "✓ Mix and match as needed"

