#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

# Multi-Pipeline Data Processing Example
# Demonstrates complex routing: ingestion -> validation -> parallel processing paths
class DataProcessingPipeline
  include Minigun::DSL

  attr_accessor :ingested, :valid, :invalid, :fast_processed, :slow_processed

  def initialize
    @ingested = []
    @valid = []
    @invalid = []
    @fast_processed = []
    @slow_processed = []
    @mutex = Mutex.new
  end

  # Pipeline 1: Ingest - Receives raw data
  pipeline :ingest, to: :validate do
    before_run { puts "Starting data processing pipeline..." }

    producer :receive_data do |output|
      puts "[Ingest] Receiving data..."
      10.times do |i|
        output << {
          id: i,
          data: "item_#{i}",
          priority: i % 3 == 0 ? :high : :normal,
          valid: i % 4 != 0  # Every 4th item is invalid
        }
      end
    end

    consumer :track do |item, output|
      @mutex.synchronize { ingested << item }
      output << item
    end
  end

  # Pipeline 2: Validate - Splits valid/invalid data
  pipeline :validate, to: [:process_fast, :process_slow] do
    processor :check_validity do |item, output|
      if item[:valid]
        output << item
      else
        @mutex.synchronize { invalid << item }
        # Invalid items don't propagate
      end
    end

    processor :prioritize do |item, output|
      puts "[Validate] Item #{item[:id]} is #{item[:priority]} priority"
      @mutex.synchronize { valid << item }
      output << item
    end

    consumer :output do |item, output|
      # Route based on priority
      if item[:priority] == :high
        # Will go to process_fast
        output << item
      else
        # Will go to both pipelines
        output << item
      end
    end
  end

  # Pipeline 3a: Fast Processing (for high-priority items)
  pipeline :process_fast do
    processor :fast_transform do |item, output|
      puts "[Fast] Processing item #{item[:id]}"
      output << item.merge(processed_by: :fast_lane)
    end

    consumer :complete do |item|
      @mutex.synchronize { fast_processed << item }
    end

    after_run { puts "Fast lane complete!" }
  end

  # Pipeline 3b: Slow Processing (for normal items)
  pipeline :process_slow do
    processor :slow_transform do |item, output|
      puts "[Slow] Processing item #{item[:id]}"
      sleep 0.01  # Simulate slower processing
      output << item.merge(processed_by: :slow_lane)
    end

    consumer :complete do |item|
      @mutex.synchronize { slow_processed << item }
    end

    after_run { puts "Slow lane complete!" }
  end
end

if __FILE__ == $0
  puts "=== Multi-Pipeline Data Processing Example ===\n\n"

  processor = DataProcessingPipeline.new
  processor.run

  puts "\n=== Processing Summary ===\n"
  puts "Ingested: #{processor.ingested.size} items"
  puts "Valid: #{processor.valid.size} items"
  puts "Invalid: #{processor.invalid.size} items (filtered out)"
  puts "Fast Lane: #{processor.fast_processed.size} items"
  puts "Slow Lane: #{processor.slow_processed.size} items"
  puts "\nTotal Processed: #{processor.fast_processed.size + processor.slow_processed.size} items"
  puts "✓ All pipelines executed successfully!"
end

