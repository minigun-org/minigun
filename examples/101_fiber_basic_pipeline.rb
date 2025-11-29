#!/usr/bin/env ruby
# frozen_string_literal: true

# Example 101: Fiber Basic Pipeline
#
# Demonstrates basic fiber usage with producer -> processor -> consumer pattern

require_relative '../lib/minigun'

puts '=' * 60
puts 'Fiber Basic Pipeline'
puts '=' * 60

unless Minigun::Platform.async?
  puts "\n⚠️  The 'async' gem is not installed."
  puts "   Add `gem 'async'` to your Gemfile and run `bundle install`"
  exit 1
end

# Basic fiber pipeline demonstrating producer -> processor -> consumer pattern
class FiberBasicPipeline
  include Minigun::DSL

  attr_reader :results

  def initialize
    @results = []
    @mutex = Mutex.new
  end

  pipeline do
    # Producer generates items
    producer :generate do |output|
      20.times { |i| output << { id: i, value: i * 10 } }
    end

    # Process items concurrently with fibers
    in_fibers(5) do
      processor :transform do |item, output|
        # Simulate async work (e.g., API call)
        sleep 0.01
        output << { id: item[:id], value: item[:value] * 2, transformed: true }
      end

      processor :enrich do |item, output|
        # Another async operation
        sleep 0.005
        item[:enriched] = true
        item[:timestamp] = Time.now.to_f
        output << item
      end
    end

    # Collect results
    consumer :collect do |item|
      @mutex.synchronize { @results << item }
    end
  end
end

start_time = Time.now
pipeline = FiberBasicPipeline.new
pipeline.run
elapsed = Time.now - start_time

puts "\nResults:"
puts "  Processed: #{pipeline.results.size} items"
puts "  All transformed: #{pipeline.results.all? { |r| r[:transformed] }}"
puts "  All enriched: #{pipeline.results.all? { |r| r[:enriched] }}"
puts "  Elapsed: #{elapsed.round(3)}s"
puts "\n✓ Basic fiber pipeline with producer -> processor -> consumer"
