#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

# Complex Reroute Example with Multiple Upstreams
# Demonstrates smart rerouting that preserves stages with remaining upstreams
class ComplexRerouteExample
  include Minigun::DSL

  attr_accessor :results

  def initialize
    @results = []
  end

  pipeline do
    # Two producers
    producer :producer_a do |output|
      puts '[ProducerA] Generating items 1-3'
      3.times { |i| output << { source: 'A', value: i + 1 } }
    end

    producer :producer_b do |output|
      puts '[ProducerB] Generating items 4-6'
      3.times { |i| output << { source: 'B', value: i + 4 } }
    end

    # Merger stage receives from BOTH producers
    # This demonstrates a stage with multiple upstreams
    processor :merger, from: %i[producer_a producer_b] do |item, output|
      merged = item.merge(merged_at: Time.now.to_f)
      puts "[Merger] Merged item from #{item[:source]}: #{item[:value]}"
      output << merged
    end

    # Another stage that only gets from producer_a
    processor :a_only, from: :producer_a do |item, output|
      processed = item.merge(processed_by: 'a_only')
      puts "[AOnly] Processed item from #{item[:source]}: #{item[:value]}"
      output << processed
    end

    # Collector receives from both merger and a_only
    consumer :collect, from: %i[merger a_only] do |item|
      puts "[Collect] Received: source=#{item[:source]}, value=#{item[:value]}, " \
           "processed_by=#{item[:processed_by] || 'merger'}"
      @results << item
    end
  end
end

# Child class that reroutes producer_a away from merger
# merger should STILL work because producer_b is still connected!
class RerouteOneUpstreamExample < ComplexRerouteExample
  pipeline do
    # Reroute producer_a away from merger, directly to collect
    # merger still has producer_b feeding it, so it should continue working
    reroute_stage :producer_a, to: :a_only

    puts '--- Routing after reroute ---'
    puts 'producer_a -> a_only -> collect'
    puts 'producer_b -> merger -> collect'
    puts 'merger keeps running because producer_b still feeds it'
  end
end

# Child class that reroutes BOTH producers away from merger
# merger should shutdown immediately (await: false auto-applied)
class RerouteBothUpstreamsExample < ComplexRerouteExample
  pipeline do
    # Reroute both producers away from merger
    # merger loses ALL upstreams and should shutdown immediately
    reroute_stage :producer_a, to: :collect
    reroute_stage :producer_b, to: :collect

    # a_only also loses its upstream and should shutdown
    # (producer_a was rerouted to :collect instead of :a_only)

    puts '--- Routing after reroute ---'
    puts 'producer_a -> collect'
    puts 'producer_b -> collect'
    puts 'merger has NO upstreams -> auto shutdown (await: false)'
    puts 'a_only has NO upstreams -> auto shutdown (await: false)'
  end
end

if __FILE__ == $PROGRAM_NAME
  puts '=' * 80
  puts 'Complex Reroute Example: Multiple Upstreams'
  puts '=' * 80

  puts "\n--- Base Pipeline ---"
  puts 'Flow:'
  puts '  producer_a -> merger -> collect'
  puts '  producer_b -> merger -> collect'
  puts '  producer_a -> a_only -> collect'
  base = ComplexRerouteExample.new
  base.run
  puts "\nResults: #{base.results.size} items"
  puts "  From merger: #{base.results.count { |r| !r[:processed_by] }}"
  puts "  From a_only: #{base.results.count { |r| r[:processed_by] == 'a_only' }}"
  puts 'Expected: 9 total (6 from merger, 3 from a_only)'

  puts "\n#{'=' * 80}"
  puts '--- Reroute One Upstream (merger keeps running) ---'
  puts 'Rerouting: producer_a away from merger'
  puts 'Result: merger still receives from producer_b!'
  reroute_one = RerouteOneUpstreamExample.new
  reroute_one.run
  puts "\nResults: #{reroute_one.results.size} items"
  puts "  From merger: #{reroute_one.results.count { |r| !r[:processed_by] }}"
  puts "  From a_only: #{reroute_one.results.count { |r| r[:processed_by] == 'a_only' }}"
  puts 'Expected: 6 total (3 from merger via producer_b, 3 from a_only)'

  puts "\n#{'=' * 80}"
  puts '--- Reroute Both Upstreams (merger shuts down) ---'
  puts 'Rerouting: both producers away from merger'
  puts 'Result: merger has NO upstreams, shuts down immediately!'
  reroute_both = RerouteBothUpstreamsExample.new
  reroute_both.run
  puts "\nResults: #{reroute_both.results.size} items"
  puts "  Direct from producers: #{reroute_both.results.count { |r| !r[:merged_at] && !r[:processed_by] }}"
  puts 'Expected: 6 total (all direct from producers, merger never ran)'

  puts "\n#{'=' * 80}"
  puts 'Key Insights'
  puts '=' * 80
  puts '✓ Stages with multiple upstreams: only shut down when ALL upstreams are gone'
  puts '✓ Rerouting automatically applies await: false to fully disconnected stages'
  puts '✓ No manual await: false needed in base class - handled automatically!'
  puts '✓ This enables flexible routing patterns without worrying about orphaned stages'
end
