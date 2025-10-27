#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

# Example 4: Complex Routing
# Multiple splits, processors, and merges
class ComplexRoutingPipeline
  include Minigun::DSL

  max_threads 5

  attr_accessor :validated, :archived, :transformed, :stored, :logged

  def initialize
    @validated = []
    @archived = []
    @transformed = []
    @stored = []
    @logged = []
    @mutex = Mutex.new
  end

  pipeline do
    # Producer splits to validator and logger
    producer :fetch, to: [:validate, :log] do |output|
      10.times { |i| output << (i + 1) }
    end

    # Validator splits to transform and archive
    processor :validate, to: [:transform, :archive] do |num, output|
      @mutex.synchronize { validated << num }
      output << num if num.even?  # Only process even numbers
    end

    # Transform and store
    processor :transform, to: :store do |num, output|
      result = num * 10
      @mutex.synchronize { transformed << result }
      output << result
    end

    # Store consumer
    consumer :store do |num|
      @mutex.synchronize { stored << num }
    end

    # Archive consumer
    consumer :archive do |num|
      @mutex.synchronize { archived << num }
    end

    # Logger consumer (logs everything from producer)
    consumer :log do |num|
      @mutex.synchronize { logged << num }
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  pipeline = ComplexRoutingPipeline.new
  pipeline.run

  puts "Complex Routing Pipeline Results:"
  puts "\nInput: 1-10"
  puts "Logged (all): #{pipeline.logged.sort.inspect}"
  puts "Validated (all): #{pipeline.validated.sort.inspect}"
  puts "Archived (evens only): #{pipeline.archived.sort.inspect}"
  puts "Transformed (evens x10): #{pipeline.transformed.sort.inspect}"
  puts "Stored (evens x10): #{pipeline.stored.sort.inspect}"
end

