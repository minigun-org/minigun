#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

# New DSL Example - Using queue arguments instead of emit
# Shows basic pipeline-to-pipeline communication
class NewDslExample
  include Minigun::DSL

  attr_accessor :results

  def initialize
    @results = []
    @mutex = Mutex.new
  end

  # First pipeline generates numbers
  pipeline :generator, to: :processor do
    # Producer: gets output queue
    producer :generate do |output|
      puts '[Generator] Creating numbers...'
      5.times { |i| output << (i + 1) }
    end

    # Processor: gets item and output queue
    processor :output do |num, output|
      puts "[Generator] Sending: #{num}"
      output << num # Send to next pipeline
    end
  end

  # Second pipeline doubles them
  pipeline :processor, to: :collector do
    processor :double do |num, output|
      doubled = num * 2
      puts "[Processor] #{num} * 2 = #{doubled}"
      output << doubled # Fixed: was outputting num instead of doubled
    end
  end

  # Third pipeline collects results
  pipeline :collector do
    # Terminal consumer: only gets item, no output
    consumer :collect do |num|
      puts "[Collector] Storing: #{num}"
      @mutex.synchronize { results << num }
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  puts "=== New DSL Example ===\n\n"
  puts "Three pipelines: Generator -> Processor -> Collector\n\n"

  example = NewDslExample.new # Fixed: was SimplePipelineExample
  example.run

  puts "\n=== Final Results ===\n"
  puts "Collected: #{example.results.sort.inspect}"
  puts 'Expected: [2, 4, 6, 8, 10]'
  puts example.results.sort == [2, 4, 6, 8, 10] ? '✓ Success!' : '✗ Failed'
end
