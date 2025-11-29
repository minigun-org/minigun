#!/usr/bin/env ruby
# frozen_string_literal: true

# Example: Cluster Worker Node
#
# This example shows how to run a worker node that connects to a coordinator.
# Workers receive work items, process them, and send results back.
#
# Usage:
#   1. Start the coordinator first: ruby examples/101_cluster_coordinator.rb
#   2. Start this worker: ruby examples/102_cluster_worker.rb
#   3. Can run multiple workers on different machines!
#
# The worker will automatically connect and register with the coordinator.

require_relative '../lib/minigun'

# Configuration
COORDINATOR_URI = ENV.fetch('COORDINATOR_URI', 'druby://127.0.0.1:9000')
WORKER_ID = ENV.fetch('WORKER_ID', nil) # Auto-generate if not specified

# Configure logging
Minigun.logger.level = Logger::INFO

puts '=== Minigun Cluster Worker Example ==='
puts "Connecting to coordinator at: #{COORDINATOR_URI}"
puts

# Create and configure worker
worker = Minigun::Cluster::Worker.new(
  coordinator_uri: COORDINATOR_URI,
  worker_id: WORKER_ID
)

# Register the stage processor(s)
# The stage name must match what the coordinator expects
worker.register_stage(:compute) do |item, output|
  # This is the same logic as in the coordinator's pipeline
  # In production, you'd have the same codebase deployed to all workers
  result = (1..10_000).reduce(item[:value]) { |acc, _| Math.sqrt(acc.abs + 1) }
  output.call({ id: item[:id], original: item[:value], computed: result.round(4) })
  puts "  Processed item #{item[:id]}: #{item[:value]} -> #{result.round(4)}"
end

# Also register as :default for flexibility
worker.register_stage(:default) do |item, output|
  puts "  [default] Processing: #{item.inspect}"
  output.call(item)
end

begin
  # Connect to coordinator
  worker.connect
  puts "Worker #{worker.worker_id} connected!"
  puts 'Waiting for work...'
  puts '(Press Ctrl+C to stop)'
  puts

  # Start processing work
  worker.start
rescue Minigun::Cluster::ConnectionError => e
  puts "Failed to connect: #{e.message}"
  puts 'Make sure the coordinator is running!'
  exit 1
rescue Interrupt
  puts
  puts 'Worker shutting down...'
  worker.stop
end

puts 'Worker stopped.'
