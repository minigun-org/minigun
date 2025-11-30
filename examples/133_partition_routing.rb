#!/usr/bin/env ruby
# frozen_string_literal: true

# Example: Partition-Based Routing
# Routes items with the same partition key to the same consumer.
# Useful for maintaining order or state per partition (e.g., by user_id, region).

require_relative '../lib/minigun'

puts 'Partition-Based Routing Demo'
puts '=' * 40
puts 'Routes items with same partition key to same consumer.'
puts

class PartitionDemo
  include Minigun::DSL

  pipeline do
    producer :source, to: %i[region_handler_a region_handler_b],
             routing: :partition, partition_key: :region do |output|
      # Simulated orders from different regions
      orders = [
        { id: 1, region: 'west', product: 'laptop' },
        { id: 2, region: 'east', product: 'phone' },
        { id: 3, region: 'west', product: 'tablet' },
        { id: 4, region: 'east', product: 'monitor' },
        { id: 5, region: 'west', product: 'keyboard' }
      ]
      orders.each { |order| output << order }
    end

    consumer :region_handler_a do |order|
      puts "  [Handler A] Order ##{order[:id]} from #{order[:region]}: #{order[:product]}"
    end

    consumer :region_handler_b do |order|
      puts "  [Handler B] Order ##{order[:id]} from #{order[:region]}: #{order[:product]}"
    end
  end
end

PartitionDemo.new.run

puts
puts "Note: All 'west' orders go to one handler, all 'east' to another."
