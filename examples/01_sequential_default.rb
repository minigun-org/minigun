#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

# Example 1: Sequential Pipeline (Default behavior)
# No routing specified - stages connect in order they're defined
class SequentialPipeline
  include Minigun::DSL

  max_threads 2

  attr_accessor :results

  def initialize
    @results = []
  end

  pipeline do
    producer :generate do |output|
      3.times { |i| output << (i + 1) }
    end

    processor :double do |num, output|
      output << num * 2
    end

    processor :add_ten do |num, output|
      output << num + 10
    end

    consumer :collect do |num|
      results << num
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  pipeline = SequentialPipeline.new
  pipeline.run

  puts "Sequential Pipeline Results:"
  puts "Input: 1, 2, 3"
  puts "After double: 2, 4, 6"
  puts "After add_ten: 12, 14, 16"
  puts "Actual results: #{pipeline.results.inspect}"
end

