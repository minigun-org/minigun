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

    # output is a SizedQueue
    producer :generate do |output|
      puts "[Generator] Creating numbers..."
      5.times { |i| output << (i + 1) }
    end

    # with stage method, both input and output are SizedQueues
    stage :forwarder do |input, output|
      while (item = input.pop) # implicit ??
        output << item * 2
      end
    end

    # Magic sauce: the output is a wrapped/proxy object around the sized queue,
    # that allows you to forward to another stage via the #to method
    # (#to returns that stage's queue). Note this can go to another pipeline.
    stage :forward_to_stage do |input, output|
      while (item = input.pop)
        output.to(:the_exit) << item + 100 # establishes a link for end-of-queue tracking
      end
    end

    # Consumer method is similar to stage, but its input arg takes the item
    # directly, there's no need to pop from the queue
    consumer :producer_consumer do |num, output|
      puts "[Generator] Sending: #{num}"
      output << num # Send to next pipeline
    end

    # Send to next pipeline
    consumer :the_pipeline_exit do |num, output|
      puts "[Generator] Sending: #{num}"
      output << num
    end
  end

  # Second pipeline doubles them
  pipeline :processor, to: :collector do
    consumer :double do |num, output|
      doubled = num * 2
      puts "[Processor] #{num} * 2 = #{doubled}"
      output << num
    end

    # Send to next pipeline
    consumer :go_out do |num|
      output << num
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
  # TODO: fix these results!!
  puts "Expected: [2, 4, 6, 8, 10]"
  puts example.results.sort == [2, 4, 6, 8, 10] ? "✓ Success!" : "✗ Failed"
end
