#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

# Simple Multi-Pipeline Example
# Shows basic pipeline-to-pipeline communication
class SimplePipelineExample
  include Minigun::DSL

  attr_accessor :results

  def initialize
    @results = []
    @mutex = Mutex.new
  end

  # First pipeline generates numbers
  pipeline :generator, to: :processor do
    producer :generate do
      puts "[Generator] Creating numbers..."
      5.times { |i| emit(i + 1) }
    end

    consumer :output do |num|
      puts "[Generator] Sending: #{num}"
      emit(num)  # Send to next pipeline
    end
  end

  # Second pipeline doubles them
  pipeline :processor, to: :collector do
    processor :double do |num|
      doubled = num * 2
      puts "[Processor] #{num} * 2 = #{doubled}"
      emit(doubled)
    end

    consumer :output do |num|
      emit(num) # Send to next pipeline
    end
  end

  # Third pipeline collects results
  pipeline :collector do
    consumer :collect do |num|
      puts "[Collector] Storing: #{num}"
      @mutex.synchronize { results << num }
    end
  end
end

if __FILE__ == $0
  puts "=== Simple Multi-Pipeline Example ===\n\n"
  puts "Three pipelines: Generator -> Processor -> Collector\n\n"

  example = SimplePipelineExample.new
  example.run

  puts "\n=== Final Results ===\n"
  puts "Collected: #{example.results.sort.inspect}"
  puts "Expected: [2, 4, 6, 8, 10]"
  puts example.results.sort == [2, 4, 6, 8, 10] ? "✓ Success!" : "✗ Failed"
end

