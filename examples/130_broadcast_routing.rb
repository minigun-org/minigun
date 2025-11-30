#!/usr/bin/env ruby
# frozen_string_literal: true

# Example: Broadcast Routing (Default)
# Each item is sent to ALL downstream consumers.
# This is the default routing behavior when multiple targets are specified.

require_relative '../lib/minigun'

puts 'Broadcast Routing Demo'
puts '=' * 40
puts 'Each item is sent to ALL consumers.'
puts

class BroadcastDemo
  include Minigun::DSL

  pipeline do
    producer :source, to: %i[consumer_a consumer_b] do |output|
      3.times { |i| output << "item_#{i}" }
    end

    consumer :consumer_a do |item|
      puts "  [A] Received: #{item}"
    end

    consumer :consumer_b do |item|
      puts "  [B] Received: #{item}"
    end
  end
end

BroadcastDemo.new.run

puts
puts 'Note: Each item appears in BOTH consumers.'
