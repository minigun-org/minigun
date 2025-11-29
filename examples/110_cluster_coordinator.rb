#!/usr/bin/env ruby
# frozen_string_literal: true

# Example: Cluster Coordinator (Head Node)
#
# This example shows how to run the coordinator/head node of a Minigun cluster.
# The coordinator distributes work to connected worker nodes.
#
# Usage:
#   1. Start the coordinator: ruby examples/101_cluster_coordinator.rb
#   2. Start workers on other machines: ruby examples/102_cluster_worker.rb
#
# The coordinator will wait for at least 1 worker before starting.

require_relative '../lib/minigun'

# Configure logging
Minigun.logger.level = Logger::INFO

puts '=== Minigun Cluster Coordinator Example ==='
puts

# Create a simple pipeline that uses cluster execution
class ClusterExample
  include Minigun::DSL

  attr_reader :results

  def initialize
    @results = []
  end

  pipeline do
    # Producer runs locally on coordinator
    producer :generate do |output|
      puts 'Generating work items...'
      20.times do |i|
        output << { id: i, value: rand(100) }
      end
      puts '20 work items generated'
    end

    # This stage runs on cluster workers
    in_cluster(coordinator: 'druby://0.0.0.0:9000', min_workers: 1, worker_timeout: 60) do
      processor :compute do |item, output|
        # Simulate CPU-intensive work
        result = (1..10_000).reduce(item[:value]) { |acc, _| Math.sqrt(acc.abs + 1) }
        output << { id: item[:id], original: item[:value], computed: result.round(4) }
      end
    end

    # Consumer runs locally on coordinator
    consumer :collect do |item|
      @results << item
    end
  end
end

puts 'Waiting for workers to connect to druby://0.0.0.0:9000 ...'
puts '(Start workers with: ruby examples/102_cluster_worker.rb)'
puts

example = ClusterExample.new

begin
  example.run
  puts
  puts '=== Results ==='
  example.results.sort_by { |r| r[:id] }.each do |r|
    puts "  Item #{r[:id]}: #{r[:original]} -> #{r[:computed]}"
  end
  puts
  puts "Total results: #{example.results.size}"
rescue Minigun::Cluster::Error => e
  puts "Cluster error: #{e.message}"
  puts 'Make sure at least 1 worker is running!'
end
