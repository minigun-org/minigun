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

# Force unbuffered output for test harness compatibility
$stdout.sync = true
$stderr.sync = true

# Configuration via environment variables for testing
CLUSTER_PORT = ENV.fetch('CLUSTER_PORT', '9000').to_i
WORKER_TIMEOUT = ENV.fetch('WORKER_TIMEOUT', '60').to_i

# Configure logging
Minigun.logger.level = Logger::INFO

puts '=== Minigun Cluster Coordinator Example ==='
puts

# Create a simple pipeline that uses cluster execution
class ClusterExample
  include Minigun::DSL

  attr_reader :results

  def initialize(port: CLUSTER_PORT)
    @results = []
    @port = port
  end

  def self.create_pipeline(port)
    Class.new do
      include Minigun::DSL

      attr_reader :results

      define_method(:initialize) do
        @results = []
      end

      pipeline do
        # Producer runs locally on coordinator
        producer :generate do |output|
          puts 'Generating work items...'
          10.times do |i|
            output << { id: i, value: rand(100) }
          end
          puts '10 work items generated'
        end

        # This stage runs on cluster workers
        in_cluster(coordinator_uri: "druby://0.0.0.0:#{port}", min_workers: 1, worker_timeout: WORKER_TIMEOUT) do
          processor :compute do |item, output|
            # Simulate CPU-intensive work (reduced for faster tests)
            result = (1..1_000).reduce(item[:value]) { |acc, _| Math.sqrt(acc.abs + 1) }
            output << { id: item[:id], original: item[:value], computed: result.round(4) }
          end
        end

        # Consumer runs locally on coordinator
        consumer :collect do |item|
          @results << item
        end
      end
    end.new
  end
end

puts "Waiting for workers to connect to druby://0.0.0.0:#{CLUSTER_PORT} ..."
puts '(Start workers with: ruby examples/111_cluster_worker.rb)'
puts

example = ClusterExample.create_pipeline(CLUSTER_PORT)

begin
  example.run
  puts
  puts '=== Results ==='
  example.results.sort_by { |r| r[:id] }.each do |r|
    puts "  Item #{r[:id]}: #{r[:original]} -> #{r[:computed]}"
  end
  puts
  puts "Total results: #{example.results.size}"
rescue Minigun::Errors::ClusterError => e
  puts "Cluster error: #{e.message}"
  puts 'Make sure at least 1 worker is running!'
end
