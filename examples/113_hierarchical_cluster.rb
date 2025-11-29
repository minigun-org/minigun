#!/usr/bin/env ruby
# frozen_string_literal: true

# Example: Hierarchical Cluster - Workers Sending to Sub-Workers
#
# Demonstrates a hierarchical cluster topology where:
# - Parent coordinator sends work to Parent Workers
# - Parent Workers fan out sub-tasks to Child Workers
# - Child Workers return results to Parent Workers
# - Parent Workers aggregate and return to Parent Coordinator
#
# Topology:
#
#   Parent Coordinator (port 9000)
#         ↓
#   Parent Worker A  →  Child Coordinator A (port 9100)
#                           ↓
#                      Child Workers (A1, A2, A3)
#
#   Parent Worker B  →  Child Coordinator B (port 9101)
#                           ↓
#                      Child Workers (B1, B2, B3)
#
# Usage:
#   Terminal 1: ruby examples/113_hierarchical_cluster.rb parent_coordinator
#   Terminal 2: ruby examples/113_hierarchical_cluster.rb child_coordinator 9100
#   Terminal 3: ruby examples/113_hierarchical_cluster.rb child_coordinator 9101
#   Terminal 4: ruby examples/113_hierarchical_cluster.rb child_worker 9100
#   Terminal 5: ruby examples/113_hierarchical_cluster.rb child_worker 9101
#   Terminal 6: ruby examples/113_hierarchical_cluster.rb parent_worker

require_relative '../lib/minigun'
require 'drb'

# Parent pipeline definition
class ParentPipeline
  include Minigun::DSL

  attr_reader :results

  def initialize
    @results = []
  end

  pipeline do
    producer :generate do |output|
      puts '[Parent Producer] Generating batches...'
      5.times do |i|
        # Each batch will be split into sub-tasks by parent workers
        output << {
          batch_id: i,
          items: (0...10).map { |j| { id: "#{i}-#{j}", value: rand(100) } }
        }
      end
      puts '[Parent Producer] Generated 5 batches'
    end

    # Parent cluster: splits batches into sub-tasks and delegates to child clusters
    in_cluster(coordinator_uri: 'druby://0.0.0.0:9000', min_workers: 1, worker_timeout: 60) do
      processor :delegate_to_children do |batch, output|
        # This runs on parent workers, which will spawn child work
        puts "  [Parent Worker] Processing batch #{batch[:batch_id]} (#{batch[:items].size} items)"

        # Parent worker delegates to child cluster and aggregates results
        # (This happens in the worker implementation below)
        output << batch
      end
    end

    consumer :collect do |result|
      @results << result
      puts "[Parent Consumer] Collected batch #{result[:batch_id]}"
    end
  end
end

# Child pipeline for processing individual items
class ChildPipeline
  include Minigun::DSL

  attr_reader :results

  def initialize
    @results = []
  end

  def process_items(items)
    @items = items
    @results = []
    run
    @results
  end

  pipeline do
    # Producer emits items from batch
    producer :emit_items do |output|
      @items.each { |item| output << item }
    end

    # Process each item
    processor :compute do |item, output|
      result = (1..1000).reduce(item[:value]) { |acc, _| Math.sqrt(acc.abs + 1) }
      output << { id: item[:id], result: result.round(4) }
    end

    # Collect results
    consumer :collect do |item|
      @results << item
    end
  end
end

# Parent worker that delegates to child cluster
def run_parent_worker(child_coordinator_port)
  worker = Minigun::Cluster::Worker.new(
    coordinator_uri: 'druby://127.0.0.1:9000',
    worker_id: "parent-worker-#{Process.pid}"
  )

  worker.register_stage(:delegate_to_children) do |batch, output|
    puts "  [Parent Worker #{Process.pid}] Delegating batch #{batch[:batch_id]} to child cluster on port #{child_coordinator_port}"

    begin
      # Connect to child cluster
      child_coordinator = DRbObject.new_with_uri("druby://127.0.0.1:#{child_coordinator_port}")

      # Send each item as work to child cluster
      batch[:items].each do |item|
        child_coordinator.enqueue_work(item)
      end

      # Signal end of work for this batch
      child_coordinator.enqueue_end_of_stage

      # Collect results from children
      child_results = []
      batch[:items].size.times do
        result = child_coordinator.collect_result(timeout: 30)
        child_results << result[:result] if result && result[:type] == :result
      end

      puts "  [Parent Worker #{Process.pid}] Collected #{child_results.size} results from children"

      # Return aggregated result
      output.call({
                    batch_id: batch[:batch_id],
                    item_count: batch[:items].size,
                    results: child_results,
                    worker_id: Process.pid
                  })
    rescue StandardError => e
      puts "  [Parent Worker #{Process.pid}] ERROR: #{e.message}"
      # Return partial result on error
      output.call({
                    batch_id: batch[:batch_id],
                    error: e.message,
                    worker_id: Process.pid
                  })
    end
  end

  worker.connect
  puts "Parent worker #{worker.worker_id} connected (using child cluster on port #{child_coordinator_port})!"
  worker.start
end

# Child coordinator that manages child workers
def run_child_coordinator(port)
  coordinator = Minigun::Cluster::Coordinator.new(
    bind_address: '127.0.0.1',
    port: port,
    stage_name: :child_compute
  )

  coordinator.start
  puts "Child coordinator started on port #{port}"
  puts 'Waiting for child workers...'
  puts '(Press Ctrl+C to stop)'

  # Keep running
  sleep
rescue Interrupt
  puts "\nChild coordinator on port #{port} shutting down..."
  coordinator.stop
end

# Child worker that processes individual items
def run_child_worker(parent_port)
  worker = Minigun::Cluster::Worker.new(
    coordinator_uri: "druby://127.0.0.1:#{parent_port}",
    worker_id: "child-worker-#{Process.pid}"
  )

  # Register to process child work items
  worker.register_stage(:default) do |item, output|
    puts "    [Child Worker #{Process.pid}] Computing item #{item[:id]}..."
    result = (1..1000).reduce(item[:value]) { |acc, _| Math.sqrt(acc.abs + 1) }
    output.call({ id: item[:id], result: result.round(4) })
  end

  worker.connect
  puts "Child worker #{worker.worker_id} connected to coordinator on port #{parent_port}!"
  worker.start
end

# Main execution
if __FILE__ == $PROGRAM_NAME
  Minigun.logger.level = Logger::INFO

  mode = ARGV[0] || 'parent_coordinator'
  port_arg = ARGV[1]&.to_i

  case mode
  when 'parent_coordinator'
    puts '=== Hierarchical Cluster - Parent Coordinator ==='
    puts
    puts 'Setup Instructions:'
    puts '1. Start child coordinators:'
    puts '     ruby examples/113_hierarchical_cluster.rb child_coordinator 9100'
    puts '     ruby examples/113_hierarchical_cluster.rb child_coordinator 9101'
    puts '2. Start child workers:'
    puts '     ruby examples/113_hierarchical_cluster.rb child_worker 9100'
    puts '     ruby examples/113_hierarchical_cluster.rb child_worker 9101'
    puts '3. Start parent workers:'
    puts '     ruby examples/113_hierarchical_cluster.rb parent_worker 9100'
    puts '     ruby examples/113_hierarchical_cluster.rb parent_worker 9101'
    puts

    pipeline = ParentPipeline.new
    pipeline.run

    puts
    puts '=== Results ==='
    pipeline.results.each do |batch|
      if batch[:error]
        puts "  Batch #{batch[:batch_id]}: ERROR - #{batch[:error]}"
      else
        puts "  Batch #{batch[:batch_id]}: #{batch[:item_count]} items, #{batch[:results]&.size || 0} results"
      end
    end
    puts
    puts "Total batches: #{pipeline.results.size}"

  when 'child_coordinator'
    unless port_arg
      puts 'ERROR: Port required for child coordinator'
      puts 'Usage: ruby examples/113_hierarchical_cluster.rb child_coordinator PORT'
      exit 1
    end

    puts "=== Child Coordinator (Port #{port_arg}) ==="
    run_child_coordinator(port_arg)

  when 'child_worker'
    unless port_arg
      puts 'ERROR: Parent port required for child worker'
      puts 'Usage: ruby examples/113_hierarchical_cluster.rb child_worker PARENT_PORT'
      exit 1
    end

    puts "=== Child Worker (Parent Port #{port_arg}) ==="
    run_child_worker(port_arg)

  when 'parent_worker'
    child_port = port_arg || 9100
    puts "=== Parent Worker (Child Cluster Port #{child_port}) ==="
    run_parent_worker(child_port)

  else
    puts "Unknown mode: #{mode}"
    puts 'Usage: ruby examples/113_hierarchical_cluster.rb [parent_coordinator|child_coordinator PORT|child_worker PARENT_PORT|parent_worker [CHILD_PORT]]'
    exit 1
  end
end
