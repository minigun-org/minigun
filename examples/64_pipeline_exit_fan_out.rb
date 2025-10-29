#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

# Example demonstrating pipeline exit with multiple terminal consumers
# Shows how a nested pipeline with fan-out (3 terminal consumers) drains to :_exit
# which forwards to the parent pipeline's consumer
class PipelineExitFanOutExample
  include Minigun::DSL

  attr_accessor :results

  def initialize
    @results = []
    @mutex = Mutex.new
  end

  # Nested pipeline with 1 producer and 3 terminal consumers (fan-out)
  # All 3 consumers are terminal (no downstream), so they all drain to :_exit
  pipeline :processor, to: :collector do
    producer :generate, routing: :broadcast do |output|
      puts '[Processor] Generating items...'
      5.times do |i|
        item = i + 1
        puts "[Processor] Produced: #{item}"
        output << item
      end
    end

    # Three terminal consumers receiving broadcast from generate
    # Each will drain to :_exit (no explicit downstream)
    consumer :even_filter, from: :generate do |item, output|
      if item.even?
        puts "[Processor] Even filter passed: #{item}"
        output << { value: item, type: :even }
      end
    end

    consumer :odd_filter, from: :generate do |item, output|
      if item.odd?
        puts "[Processor] Odd filter passed: #{item}"
        output << { value: item, type: :odd }
      end
    end

    consumer :all_logger, from: :generate do |item, output|
      puts "[Processor] All logger saw: #{item}"
      output << { value: item, type: :all }
    end
  end

  # Parent pipeline consumer that receives from all 3 terminal consumers
  pipeline :collector do
    consumer :collect do |item|
      puts "[Collector] Received: #{item.inspect}"
      @mutex.synchronize { results << item }
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  puts "=== Pipeline Exit Fan-Out Example ===\n\n"
  puts "Nested pipeline topology:"
  puts "  generate -> [even_filter, odd_filter, all_logger]"
  puts "  All 3 consumers are terminal, so they drain to :_exit"
  puts "  :_exit forwards to parent pipeline's collector\n\n"

  example = PipelineExitFanOutExample.new
  example.run

  puts "\n=== Results ==="
  puts "Total items collected: #{example.results.size}"

  even_items = example.results.select { |r| r[:type] == :even }
  odd_items = example.results.select { |r| r[:type] == :odd }
  all_items = example.results.select { |r| r[:type] == :all }

  puts "Even items: #{even_items.map { |r| r[:value] }.sort.inspect}"
  puts "Odd items: #{odd_items.map { |r| r[:value] }.sort.inspect}"
  puts "All items: #{all_items.map { |r| r[:value] }.sort.inspect}"

  # Verify we got the right counts
  expected_even = [2, 4]
  expected_odd = [1, 3, 5]
  expected_all = [1, 2, 3, 4, 5]

  success = even_items.map { |r| r[:value] }.sort == expected_even &&
            odd_items.map { |r| r[:value] }.sort == expected_odd &&
            all_items.map { |r| r[:value] }.sort == expected_all

  puts "\n#{success ? '✓ Success!' : '✗ Failed'}"
  puts "Expected: 2 even + 3 odd + 5 all = 10 total items"
  puts "Got: #{even_items.size} even + #{odd_items.size} odd + #{all_items.size} all = #{example.results.size} total items"
end

