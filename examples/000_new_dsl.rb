#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

# Forked from 05_multi_pipeline_simple.rb
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
    # Producer: receives output queue only
    producer :generate do |output|
      puts '[Generator] Creating numbers...'
      5.times do |i|
        num = i + 1
        puts "[Generator] Sending: #{num}"
        output << num
      end
    end
  end

  # Second pipeline doubles them
  pipeline :processor, to: :collector do
    processor :double do |num, output|
      doubled = num * 2
      puts "[Processor] #{num} * 2 = #{doubled}"
      output << doubled
    end
  end

  # Third pipeline collects results. Note only one block arg.
  pipeline :collector do
    consumer :collect do |num|
      puts "[Collector] Storing: #{num}"
      @mutex.synchronize { results << num }
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  puts "=== New DSL Example ===\n\n"
  puts "Three pipelines: Generator -> Processor -> Collector\n\n"

  example = NewDslExample.new
  example.run

  puts "\n=== Final Results ===\n"
  puts "Collected: #{example.results.sort.inspect}"
  puts 'Expected: [2, 4, 6, 8, 10]'
  puts example.results.sort == [2, 4, 6, 8, 10] ? '✓ Success!' : '✗ Failed'
end
