#!/usr/bin/env ruby
# frozen_string_literal: true

# Example: Cluster Direct Mode (No Coordinator)
#
# Demonstrates connecting directly to worker nodes without a coordinator.
# In direct mode:
# - Work items are distributed round-robin to workers
# - No central coordinator needed
# - Simpler setup for static worker pools
# - Workers must be started before the pipeline
#
# Use cases:
# - Known, static set of workers
# - Simpler deployment (no coordinator process)
# - Pre-provisioned worker fleet
#
# Topology:
#
#   Producer (local)
#        ↓
#   Direct distribution (round-robin)
#        ↓
#   ┌─────────┬─────────┬─────────┐
#   │Worker 1 │Worker 2 │Worker 3 │  (all running on different ports)
#   │:9001    │:9002    │:9003    │
#   └─────────┴─────────┴─────────┘
#        ↓
#   Consumer (local)
#
# Usage:
#   Terminal 1: ruby examples/118_cluster_direct_mode.rb worker 9001
#   Terminal 2: ruby examples/118_cluster_direct_mode.rb worker 9002
#   Terminal 3: ruby examples/118_cluster_direct_mode.rb worker 9003
#   Terminal 4: ruby examples/118_cluster_direct_mode.rb client
#
# Or run loopback test (all in one process):
#   ruby examples/118_cluster_direct_mode.rb loopback

require_relative '../lib/minigun'
require 'drb'

# Force unbuffered output for test harness compatibility
$stdout.sync = true
$stderr.sync = true

# Configuration via environment variables for testing
CLUSTER_PORT = ENV.fetch('CLUSTER_PORT', '9001').to_i

# Pipeline that connects directly to workers (no coordinator)
class DirectModePipeline
  include Minigun::DSL

  attr_reader :results

  def initialize(worker_uris:)
    @worker_uris = worker_uris
    @results = []
  end

  pipeline do
    # Generate work items locally
    producer :generate do |output|
      puts '[Producer] Generating work items...'
      15.times do |i|
        output << { id: i, value: rand(100) }
      end
      puts '[Producer] Generated 15 work items'
    end

    # Direct mode: connect to workers without coordinator
    # Works are distributed round-robin across the worker URIs
    in_cluster(worker_uris: @worker_uris) do
      processor :compute do |item, output|
        # Simulate computation
        result = (1..5000).reduce(item[:value]) { |acc, _| Math.sqrt(acc.abs + 1) }
        output << { id: item[:id], original: item[:value], computed: result.round(4) }
      end
    end

    # Collect results locally
    consumer :collect do |item|
      @results << item
      puts "[Consumer] Collected result for item #{item[:id]}"
    end
  end
end

# Start a worker node
def run_worker(port)
  # Create worker
  worker = Minigun::Cluster::Worker.new(
    coordinator_uri: nil, # Not connecting to a coordinator
    worker_id: "direct-worker-#{port}"
  )

  # Register the computation stage
  worker.register_stage(:compute) do |item, output|
    puts "[Worker #{port}] Processing item #{item[:id]} (value: #{item[:value]})"
    result = (1..5000).reduce(item[:value]) { |acc, _| Math.sqrt(acc.abs + 1) }
    output.call({ id: item[:id], original: item[:value], computed: result.round(4) })
  end

  # Start DRb service directly (without connecting to coordinator)
  # The WorkerService allows direct item processing via process_item
  service = Minigun::Cluster::WorkerService.new(worker)
  DRb.start_service("druby://0.0.0.0:#{port}", service)

  puts "Direct mode worker started at druby://0.0.0.0:#{port}"
  puts 'Press Ctrl+C to stop'

  # Keep running
  DRb.thread.join
rescue Interrupt
  puts "\nWorker stopping..."
  DRb.stop_service
end

# Run loopback test (all in one process for testing)
def run_loopback_test
  puts '=== Loopback Test (Single Process) ==='
  puts 'Starting 3 workers in background threads...'

  workers = []
  services = []
  worker_uris = []

  # Start 3 workers in background
  [9001, 9002, 9003].each do |port|
    worker = Minigun::Cluster::Worker.new(
      coordinator_uri: nil,
      worker_id: "loopback-worker-#{port}"
    )

    worker.register_stage(:compute) do |item, output|
      puts "  [Worker #{port}] Processing item #{item[:id]}"
      result = (1..1000).reduce(item[:value]) { |acc, _| Math.sqrt(acc.abs + 1) }
      output.call({ id: item[:id], original: item[:value], computed: result.round(4), worker: port })
    end

    service = Minigun::Cluster::WorkerService.new(worker)
    uri = "druby://127.0.0.1:#{port}"
    DRb.start_service(uri, service)

    workers << worker
    services << service
    worker_uris << uri

    puts "  Worker started at #{uri}"
  end

  puts
  puts 'Running pipeline with direct mode...'
  puts

  pipeline = DirectModePipeline.new(worker_uris: worker_uris)
  pipeline.run

  puts
  puts '=== Results ==='
  pipeline.results.sort_by { |r| r[:id] }.each do |r|
    worker_info = r[:worker] ? " (worker: #{r[:worker]})" : ''
    puts "  Item #{r[:id]}: #{r[:original]} -> #{r[:computed]}#{worker_info}"
  end
  puts
  puts "Total: #{pipeline.results.size} items processed"

  # Verify round-robin distribution
  worker_counts = pipeline.results.group_by { |r| r[:worker] }.transform_values(&:size)
  puts
  puts 'Work distribution:'
  worker_counts.each do |worker, count|
    puts "  Worker #{worker}: #{count} items"
  end
rescue StandardError => e
  puts "Error: #{e.message}"
  puts e.backtrace.first(5).join("\n")
ensure
  DRb.stop_service
end

# Main execution
if __FILE__ == $PROGRAM_NAME
  Minigun.logger.level = Logger::INFO

  mode = ARGV[0] || 'help'

  case mode
  when 'worker'
    port = ARGV[1]&.to_i || CLUSTER_PORT
    puts "=== Direct Mode Worker (Port #{port}) ==="
    run_worker(port)

  when 'client'
    # Get worker ports from args or ENV-based defaults
    worker_ports = if ARGV.size > 1
                     ARGV[1..].map(&:to_i)
                   else
                     [CLUSTER_PORT, CLUSTER_PORT + 1, CLUSTER_PORT + 2]
                   end
    worker_uris = worker_ports.map { |p| "druby://127.0.0.1:#{p}" }

    puts '=== Direct Mode Client ==='
    puts
    puts "Connecting to workers: #{worker_uris.join(', ')}"
    puts

    DRb.start_service

    pipeline = DirectModePipeline.new(worker_uris: worker_uris)

    begin
      pipeline.run

      puts
      puts '=== Results ==='
      pipeline.results.sort_by { |r| r[:id] }.each do |r|
        puts "  Item #{r[:id]}: #{r[:original]} -> #{r[:computed]}"
      end
      puts
      puts "Total: #{pipeline.results.size} items processed"
      puts 'SUCCESS' if pipeline.results.size == 15
    rescue Minigun::Errors::ClusterError => e
      puts "Cluster error: #{e.message}"
      puts 'Make sure all workers are running!'
      exit 1
    end

  when 'loopback'
    run_loopback_test

  when 'help', '--help', '-h'
    puts '=== Cluster Direct Mode Example ==='
    puts
    puts 'Demonstrates connecting directly to workers without a coordinator.'
    puts 'In direct mode, work is distributed round-robin to workers.'
    puts
    puts 'Usage:'
    puts '  worker PORT  - Start a worker on the given port'
    puts '  client       - Run the pipeline (connect to workers on 9001-9003)'
    puts '  loopback     - Run self-contained test (workers + client in one process)'
    puts
    puts 'Multi-terminal setup:'
    puts '  Terminal 1: ruby examples/118_cluster_direct_mode.rb worker 9001'
    puts '  Terminal 2: ruby examples/118_cluster_direct_mode.rb worker 9002'
    puts '  Terminal 3: ruby examples/118_cluster_direct_mode.rb worker 9003'
    puts '  Terminal 4: ruby examples/118_cluster_direct_mode.rb client'
    puts
    puts 'Single-process test:'
    puts '  ruby examples/118_cluster_direct_mode.rb loopback'

  else
    puts "Unknown mode: #{mode}"
    puts 'Run with --help for usage'
    exit 1
  end
end
