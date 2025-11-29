#!/usr/bin/env ruby
# frozen_string_literal: true

# Example: Cluster Loopback / Circular Topology
#
# Demonstrates a circular cluster topology where:
# - Node A sends work to Node B
# - Node B processes and sends to Node C
# - Node C processes and sends BACK to Node A for final processing
#
# Use cases:
# - Iterative algorithms (converge until stable)
# - Multi-pass processing (refine results)
# - Feedback loops (validation → correction → re-validation)
#
# Topology:
#
# Node A (port 9000)
# - initial_process
# - final_collect  ◄───────────────┐
#   │                              │
#   ▼                              │
# Node B (port 9001)               │
# - transform                      │
#   │                              │
#   ▼                              │
# Node C (port 9002)               │
# - validate_and_loopback ─────────┘
#   (sends back to Node A:final_collect)
#
# Work flow: A → B → C → A (loopback)
#
# Usage:
#   Terminal 1: ruby examples/117_cluster_loopback.rb coordinator_a
#   Terminal 2: ruby examples/117_cluster_loopback.rb coordinator_b
#   Terminal 3: ruby examples/117_cluster_loopback.rb coordinator_c
#   Terminal 4: ruby examples/117_cluster_loopback.rb worker_a
#   Terminal 5: ruby examples/117_cluster_loopback.rb worker_b
#   Terminal 6: ruby examples/117_cluster_loopback.rb worker_c

require_relative '../lib/minigun'
require 'drb'

# Shared constants
NODE_A_PORT = 9000
NODE_B_PORT = 9001
NODE_C_PORT = 9002

# Node A: Initial processing and final collection
# This node has TWO stages:
# 1. initial_process - sends work to Node B
# 2. final_collect - receives processed results from Node C (loopback)
class NodeAPipeline
  include Minigun::DSL

  attr_reader :results, :loopback_coordinator

  def initialize
    @results = []
    @loopback_coordinator = nil
  end

  def start_loopback_receiver
    # Start a separate coordinator to receive loopback results from Node C
    @loopback_coordinator = Minigun::Cluster::Coordinator.new(
      bind_address: '127.0.0.1',
      port: NODE_A_PORT + 100, # Port 9100 for loopback
      stage_name: :final_collect
    )
    @loopback_coordinator.start
    puts "[Node A] Loopback receiver started on port #{NODE_A_PORT + 100}"

    # Background thread to collect loopback results
    Thread.new do
      loop do
        result = @loopback_coordinator.collect_result
        break if result.nil?

        if result[:type] == :result
          @results << result[:result]
          puts "[Node A] Received loopback result: item #{result[:result][:id]} (iteration #{result[:result][:iteration]})"
        end
      end
    end
  end

  def stop_loopback_receiver
    @loopback_coordinator&.stop
  end

  pipeline do
    # Generate initial work items
    producer :generate do |output|
      puts '[Node A] Generating initial work items...'
      10.times do |i|
        output << { id: i, value: rand(100), iteration: 0, history: ['generated'] }
      end
      puts '[Node A] Generated 10 work items'
    end

    # Initial processing - sends to Node B
    in_cluster(coordinator_uri: "druby://0.0.0.0:#{NODE_A_PORT}", min_workers: 1, worker_timeout: 60) do
      processor :initial_process do |item, output|
        # Add initial processing
        processed = item.merge(
          value: item[:value] * 2,
          history: item[:history] + ['node_a_initial']
        )
        output << processed
      end
    end

    # Local consumer just to complete the pipeline
    # (Real results come via loopback)
    consumer :forward_to_b do |item|
      # Forward to Node B via DRb

      node_b = DRbObject.new_with_uri("druby://127.0.0.1:#{NODE_B_PORT}")
      node_b.enqueue_work({ stage: :transform, item: item })
      puts "[Node A] Forwarded item #{item[:id]} to Node B"
    rescue StandardError => e
      puts "[Node A] ERROR forwarding to Node B: #{e.message}"
    end
  end
end

# Node B: Transform stage
def run_node_b_coordinator
  coordinator = Minigun::Cluster::Coordinator.new(
    bind_address: '127.0.0.1',
    port: NODE_B_PORT,
    stage_name: :transform
  )

  coordinator.start
  puts "[Node B] Coordinator started on port #{NODE_B_PORT}"
  puts '[Node B] Waiting for workers and work items...'

  # Keep running
  sleep
rescue Interrupt
  puts "\n[Node B] Shutting down..."
  coordinator.stop
end

def run_node_b_worker
  worker = Minigun::Cluster::Worker.new(
    coordinator_uri: "druby://127.0.0.1:#{NODE_B_PORT}",
    worker_id: "node-b-worker-#{Process.pid}"
  )

  worker.register_stage(:transform) do |item, output|
    puts "[Node B Worker] Transforming item #{item[:id]}..."

    # Transform the data
    transformed = item.merge(
      value: Math.sqrt(item[:value]).round(2),
      iteration: item[:iteration] + 1,
      history: item[:history] + ['node_b_transform']
    )

    # Forward to Node C
    begin
      node_c = DRbObject.new_with_uri("druby://127.0.0.1:#{NODE_C_PORT}")
      node_c.enqueue_work({ stage: :validate, item: transformed })
      puts "[Node B Worker] Forwarded item #{item[:id]} to Node C"
    rescue StandardError => e
      puts "[Node B Worker] ERROR forwarding to Node C: #{e.message}"
    end

    # Return empty result (we forwarded, not returning to our coordinator)
    output.call({ forwarded: true, id: item[:id] })
  end

  worker.connect
  puts '[Node B] Worker connected!'
  worker.start
end

# Node C: Validate and loopback to Node A
def run_node_c_coordinator
  coordinator = Minigun::Cluster::Coordinator.new(
    bind_address: '127.0.0.1',
    port: NODE_C_PORT,
    stage_name: :validate
  )

  coordinator.start
  puts "[Node C] Coordinator started on port #{NODE_C_PORT}"
  puts '[Node C] Waiting for workers and work items...'

  # Keep running
  sleep
rescue Interrupt
  puts "\n[Node C] Shutting down..."
  coordinator.stop
end

def run_node_c_worker
  worker = Minigun::Cluster::Worker.new(
    coordinator_uri: "druby://127.0.0.1:#{NODE_C_PORT}",
    worker_id: "node-c-worker-#{Process.pid}"
  )

  worker.register_stage(:validate) do |item, output|
    puts "[Node C Worker] Validating item #{item[:id]}..."

    # Validate and finalize
    validated = item.merge(
      validated: true,
      history: item[:history] + ['node_c_validate'],
      completed_at: Time.now.to_i
    )

    # LOOPBACK: Send back to Node A's final_collect stage
    begin
      node_a_loopback = DRbObject.new_with_uri("druby://127.0.0.1:#{NODE_A_PORT + 100}")
      node_a_loopback.submit_result({
                                      type: :result,
                                      result: validated,
                                      worker_id: "node-c-worker-#{Process.pid}"
                                    })
      puts "[Node C Worker] LOOPBACK: Sent item #{item[:id]} back to Node A!"
    rescue StandardError => e
      puts "[Node C Worker] ERROR in loopback to Node A: #{e.message}"
    end

    output.call({ loopback_sent: true, id: item[:id] })
  end

  worker.connect
  puts '[Node C] Worker connected!'
  worker.start
end

# Main execution
if __FILE__ == $PROGRAM_NAME
  Minigun.logger.level = Logger::INFO
  DRb.start_service

  mode = ARGV[0] || 'help'

  case mode
  when 'coordinator_a'
    puts '=== Node A: Initial Processing + Loopback Receiver ==='
    puts
    puts 'This is the main coordinator that:'
    puts '  1. Generates initial work'
    puts '  2. Processes and forwards to Node B'
    puts '  3. Receives final results via loopback from Node C'
    puts
    puts 'Start other nodes first:'
    puts '  ruby examples/117_cluster_loopback.rb coordinator_b'
    puts '  ruby examples/117_cluster_loopback.rb coordinator_c'
    puts '  ruby examples/117_cluster_loopback.rb worker_b'
    puts '  ruby examples/117_cluster_loopback.rb worker_c'
    puts '  ruby examples/117_cluster_loopback.rb worker_a'
    puts

    pipeline = NodeAPipeline.new

    # Start loopback receiver first
    pipeline.start_loopback_receiver
    sleep 1 # Wait for it to start

    # Run main pipeline
    pipeline.run

    # Wait for loopback results
    puts
    puts '[Node A] Waiting for loopback results...'
    sleep 5 # Give time for results to loop back

    pipeline.stop_loopback_receiver

    puts
    puts '=== RESULTS (via loopback from Node C) ==='
    puts "Total results received: #{pipeline.results.size}"
    puts
    pipeline.results.sort_by { |r| r[:id] }.each do |r|
      puts "  Item #{r[:id]}:"
      puts "    Final value: #{r[:value]}"
      puts "    Iterations: #{r[:iteration]}"
      puts "    History: #{r[:history].join(' → ')}"
      puts "    Validated: #{r[:validated]}"
      puts
    end

  when 'coordinator_b'
    puts '=== Node B: Transform Coordinator ==='
    run_node_b_coordinator

  when 'coordinator_c'
    puts '=== Node C: Validate & Loopback Coordinator ==='
    run_node_c_coordinator

  when 'worker_a'
    puts '=== Node A Worker ==='
    worker = Minigun::Cluster::Worker.new(
      coordinator_uri: "druby://127.0.0.1:#{NODE_A_PORT}",
      worker_id: "node-a-worker-#{Process.pid}"
    )

    worker.register_stage(:initial_process) do |item, output|
      puts "[Node A Worker] Initial processing item #{item[:id]}..."
      processed = item.merge(
        value: item[:value] * 2,
        history: item[:history] + ['node_a_initial']
      )
      output.call(processed)
    end

    worker.connect
    puts '[Node A] Worker connected!'
    worker.start

  when 'worker_b'
    puts '=== Node B Worker ==='
    run_node_b_worker

  when 'worker_c'
    puts '=== Node C Worker ==='
    run_node_c_worker

  when 'help', '--help', '-h'
    puts '=== Cluster Loopback Example ==='
    puts
    puts 'Demonstrates circular cluster topology: A → B → C → A'
    puts
    puts 'Topology:'
    puts '  Node A (port 9000) - initial processing'
    puts '      ↓'
    puts '  Node B (port 9001) - transformation'
    puts '      ↓'
    puts '  Node C (port 9002) - validation'
    puts '      ↓'
    puts '  Node A (port 9100) - loopback receiver'
    puts
    puts 'Start order:'
    puts '  1. ruby examples/117_cluster_loopback.rb coordinator_b'
    puts '  2. ruby examples/117_cluster_loopback.rb coordinator_c'
    puts '  3. ruby examples/117_cluster_loopback.rb worker_b'
    puts '  4. ruby examples/117_cluster_loopback.rb worker_c'
    puts '  5. ruby examples/117_cluster_loopback.rb worker_a'
    puts '  6. ruby examples/117_cluster_loopback.rb coordinator_a'
    puts
    puts 'Modes:'
    puts '  coordinator_a - Main coordinator (start last)'
    puts '  coordinator_b - Node B coordinator'
    puts '  coordinator_c - Node C coordinator'
    puts '  worker_a      - Node A worker'
    puts '  worker_b      - Node B worker (forwards to C)'
    puts '  worker_c      - Node C worker (loops back to A)'

  else
    puts "Unknown mode: #{mode}"
    puts 'Run with --help for usage'
    exit 1
  end
end
