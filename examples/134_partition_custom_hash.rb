#!/usr/bin/env ruby
# frozen_string_literal: true

# Example: Partition with Custom Hash Function
# Uses a custom hash function for explicit routing control.
# The hash function returns the partition index (0 to n-1).

require_relative '../lib/minigun'

puts 'Partition with Custom Hash Demo'
puts '=' * 40
puts 'Uses custom hash function for explicit routing control.'
puts

# Demonstrates partition with custom hash function
class CustomPartitionDemo
  include Minigun::DSL

  pipeline do
    # Custom hash: route based on item value mod 3
    producer :source, to: %i[bucket0 bucket1 bucket2],
                      routing: :partition, hash: ->(item) { item % 3 } do |output|
      9.times { |i| output << i }
    end

    consumer :bucket0 do |item|
      puts "  [Bucket 0] #{item}"
    end

    consumer :bucket1 do |item|
      puts "  [Bucket 1] #{item}"
    end

    consumer :bucket2 do |item|
      puts "  [Bucket 2] #{item}"
    end
  end
end

CustomPartitionDemo.new.run

puts
puts 'Note: 0,3,6 -> Bucket 0; 1,4,7 -> Bucket 1; 2,5,8 -> Bucket 2'
