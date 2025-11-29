#!/usr/bin/env ruby
# frozen_string_literal: true

# Example 107: Fiber Fan-Out/Fan-In Pattern
#
# Demonstrates broadcasting items to multiple fiber pools,
# then merging results back together

require_relative '../lib/minigun'

puts '=' * 60
puts 'Fiber Fan-Out/Fan-In Pattern'
puts '=' * 60

unless Minigun::Platform.async?
  puts "\n⚠️  The 'async' gem is not installed."
  exit 1
end

class FiberFanOutFanIn
  include Minigun::DSL

  attr_reader :results, :path_a_count, :path_b_count, :path_c_count

  def initialize
    @results = []
    @path_a_count = 0
    @path_b_count = 0
    @path_c_count = 0
    @mutex = Mutex.new
  end

  pipeline do
    produce_each :items, (1..15).to_a

    # Router splits items to three paths based on modulo
    processor :router do |item, output|
      case item % 3
      when 0 then output.to(:path_a) << item
      when 1 then output.to(:path_b) << item
      else output.to(:path_c) << item
      end
    end

    # Path A: High concurrency fiber pool
    in_fibers(5) do
      processor :path_a, await: true do |item, output|
        @mutex.synchronize { @path_a_count += 1 }
        sleep 0.01
        output << { value: item, path: 'A', multiplied: item * 10 }
      end
    end

    # Path B: Medium concurrency fiber pool
    in_fibers(3) do
      processor :path_b, await: true do |item, output|
        @mutex.synchronize { @path_b_count += 1 }
        sleep 0.015
        output << { value: item, path: 'B', squared: item ** 2 }
      end
    end

    # Path C: Lower concurrency fiber pool
    in_fibers(2) do
      processor :path_c, await: true do |item, output|
        @mutex.synchronize { @path_c_count += 1 }
        sleep 0.02
        output << { value: item, path: 'C', cubed: item ** 3 }
      end
    end

    # Fan-in: collect all paths
    consumer :merger, from: %i[path_a path_b path_c] do |item|
      @mutex.synchronize { @results << item }
    end
  end
end

start_time = Time.now
pipeline = FiberFanOutFanIn.new
pipeline.run
elapsed = Time.now - start_time

puts "\nResults:"
puts "  Total processed: #{pipeline.results.size} items"
puts "  Path A count: #{pipeline.path_a_count} (items % 3 == 0)"
puts "  Path B count: #{pipeline.path_b_count} (items % 3 == 1)"
puts "  Path C count: #{pipeline.path_c_count} (items % 3 == 2)"

by_path = pipeline.results.group_by { |r| r[:path] }
puts "\nPath breakdown:"
by_path.each do |path, items|
  puts "  Path #{path}: #{items.map { |i| i[:value] }.sort.join(', ')}"
end

puts "  Elapsed: #{elapsed.round(3)}s"
puts "\n✓ Fan-out to multiple fiber pools"
puts "✓ Fan-in merges all results"
