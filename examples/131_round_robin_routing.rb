#!/usr/bin/env ruby
# frozen_string_literal: true

# Example: Round-Robin Routing
# Items are distributed evenly across consumers in order.
# Each item goes to exactly ONE consumer, alternating between them.

require_relative '../lib/minigun'

puts 'Round-Robin Routing Demo'
puts '=' * 40
puts 'Items are distributed evenly across consumers in order.'
puts

# Demonstrates round-robin routing
class RoundRobinDemo
  include Minigun::DSL

  pipeline do
    producer :source, to: %i[consumer_a consumer_b], routing: :round_robin do |output|
      6.times { |i| output << "item_#{i}" }
    end

    consumer :consumer_a do |item|
      puts "  [A] Received: #{item}"
    end

    consumer :consumer_b do |item|
      puts "  [B] Received: #{item}"
    end
  end
end

RoundRobinDemo.new.run

puts
puts 'Note: Items alternate between A and B (each gets 3 items).'
