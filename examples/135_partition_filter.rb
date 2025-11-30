#!/usr/bin/env ruby
# frozen_string_literal: true

# Example: Partition with Filter
# Custom hash function can return :none to discard items.
# This allows filtering during routing.

require_relative '../lib/minigun'

puts 'Partition with Filter Demo'
puts '=' * 40
puts 'Custom hash returning :none discards the item.'
puts

# Demonstrates partition with filter (hash returns :none)
class FilterPartitionDemo
  include Minigun::DSL

  pipeline do
    # Filter: only keep positive numbers, discard zero and negatives
    producer :source, to: %i[positive_a positive_b],
                      routing: :partition, hash: ->(item) { item > 0 ? item % 2 : :none } do |output|
      [-2, -1, 0, 1, 2, 3, 4, 5].each { |i| output << i }
    end

    consumer :positive_a do |item|
      puts "  [Positive A] #{item}"
    end

    consumer :positive_b do |item|
      puts "  [Positive B] #{item}"
    end
  end
end

FilterPartitionDemo.new.run

puts
puts 'Note: -2, -1, and 0 were filtered out (hash returned :none).'
