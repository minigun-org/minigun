#!/usr/bin/env ruby
# frozen_string_literal: true

# Example: Demand-Based Routing
# Routes items to the consumer with the most available queue capacity.
# Falls back to round-robin for unbounded queues.
#
# This is useful for load balancing when consumers have different processing speeds.

require_relative '../lib/minigun'

puts 'Demand-Based Routing Demo'
puts '=' * 40
puts 'Routes to consumer with most available queue capacity.'
puts

class DemandDemo
  include Minigun::DSL

  pipeline do
    # Using queue_size creates SizedQueue for capacity-based routing
    producer :source, to: %i[fast_consumer slow_consumer], routing: :demand do |output|
      10.times { |i| output << "item_#{i}" }
    end

    consumer :fast_consumer, queue_size: 5 do |item|
      puts "  [FAST] Received: #{item}"
    end

    consumer :slow_consumer, queue_size: 5 do |item|
      sleep 0.05 # Slow consumer
      puts "  [SLOW] Received: #{item}"
    end
  end
end

DemandDemo.new.run

puts
puts 'Note: Fast consumer typically receives more items due to higher availability.'
