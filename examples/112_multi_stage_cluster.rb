#!/usr/bin/env ruby
# frozen_string_literal: true

# Example: Multi-Stage Cluster Pipeline
#
# Demonstrates a pipeline with MULTIPLE cluster stages in sequence.
# Each cluster stage can have different worker pools.
#
# Topology:
#   Producer (local)
#     ↓
#   Cluster A: preprocessing (port 9000, 3 workers)
#     ↓
#   Cluster B: heavy_compute (port 9001, 5 workers)
#     ↓
#   Cluster C: postprocessing (port 9002, 2 workers)
#     ↓
#   Consumer (local)
#
# Usage:
#   Terminal 1: ruby examples/112_multi_stage_cluster.rb coordinator
#   Terminal 2: ruby examples/112_multi_stage_cluster.rb worker_preprocess
#   Terminal 3: ruby examples/112_multi_stage_cluster.rb worker_compute
#   Terminal 4: ruby examples/112_multi_stage_cluster.rb worker_postprocess

require_relative '../lib/minigun'

# Pipeline definition
class MultiStageCluster
  include Minigun::DSL

  attr_reader :results

  def initialize
    @results = []
  end

  pipeline do
    # Generate work items locally
    producer :generate do |output|
      puts '[Producer] Generating 10 work items...'
      10.times do |i|
        output << { id: i, value: rand(100) }
      end
      puts '[Producer] Done generating'
    end

    # Stage 1: Preprocessing cluster (port 9000)
    in_cluster(coordinator: 'druby://0.0.0.0:9000', min_workers: 1, worker_timeout: 30) do
      processor :preprocess do |item, output|
        # Simulate preprocessing (validation, normalization, etc.)
        puts "  [Preprocess] Item #{item[:id]}: validating..."
        sleep 0.1
        normalized = item[:value] * 2
        output << { id: item[:id], preprocessed: normalized }
      end
    end

    # Stage 2: Heavy computation cluster (port 9001)
    in_cluster(coordinator: 'druby://0.0.0.0:9001', min_workers: 1, worker_timeout: 30) do
      processor :heavy_compute do |item, output|
        # Simulate expensive computation
        puts "  [Compute] Item #{item[:id]}: computing..."
        sleep 0.2
        result = (1..5000).reduce(item[:preprocessed]) { |acc, _| Math.sqrt(acc.abs + 1) }
        output << { id: item[:id], computed: result.round(4) }
      end
    end

    # Stage 3: Postprocessing cluster (port 9002)
    in_cluster(coordinator: 'druby://0.0.0.0:9002', min_workers: 1, worker_timeout: 30) do
      processor :postprocess do |item, output|
        # Simulate postprocessing (formatting, validation, etc.)
        puts "  [Postprocess] Item #{item[:id]}: formatting..."
        sleep 0.1
        formatted = {
          id: item[:id],
          result: item[:computed],
          status: 'completed',
          timestamp: Time.now.to_i
        }
        output << formatted
      end
    end

    # Collect results locally
    consumer :collect do |item|
      @results << item
      puts "[Consumer] Collected result for item #{item[:id]}"
    end
  end
end

# Worker implementations
def run_preprocess_worker
  worker = Minigun::Cluster::Worker.new(
    coordinator_uri: 'druby://127.0.0.1:9000',
    worker_id: "preprocess-#{Process.pid}"
  )

  worker.register_stage(:preprocess) do |item, output|
    puts "  [Preprocess Worker] Item #{item[:id]}: validating..."
    sleep 0.1
    normalized = item[:value] * 2
    output.call({ id: item[:id], preprocessed: normalized })
  end

  worker.connect
  puts "Preprocess worker #{worker.worker_id} connected!"
  worker.start
end

def run_compute_worker
  worker = Minigun::Cluster::Worker.new(
    coordinator_uri: 'druby://127.0.0.1:9001',
    worker_id: "compute-#{Process.pid}"
  )

  worker.register_stage(:heavy_compute) do |item, output|
    puts "  [Compute Worker] Item #{item[:id]}: computing..."
    sleep 0.2
    result = (1..5000).reduce(item[:preprocessed]) { |acc, _| Math.sqrt(acc.abs + 1) }
    output.call({ id: item[:id], computed: result.round(4) })
  end

  worker.connect
  puts "Compute worker #{worker.worker_id} connected!"
  worker.start
end

def run_postprocess_worker
  worker = Minigun::Cluster::Worker.new(
    coordinator_uri: 'druby://127.0.0.1:9002',
    worker_id: "postprocess-#{Process.pid}"
  )

  worker.register_stage(:postprocess) do |item, output|
    puts "  [Postprocess Worker] Item #{item[:id]}: formatting..."
    sleep 0.1
    formatted = {
      id: item[:id],
      result: item[:computed],
      status: 'completed',
      timestamp: Time.now.to_i
    }
    output.call(formatted)
  end

  worker.connect
  puts "Postprocess worker #{worker.worker_id} connected!"
  worker.start
end

# Main execution
if __FILE__ == $PROGRAM_NAME
  Minigun.logger.level = Logger::INFO

  mode = ARGV[0] || 'coordinator'

  case mode
  when 'coordinator'
    puts '=== Multi-Stage Cluster Coordinator ==='
    puts 'Starting coordinator with 3 cluster stages...'
    puts 'Start workers in separate terminals:'
    puts '  ruby examples/112_multi_stage_cluster.rb worker_preprocess'
    puts '  ruby examples/112_multi_stage_cluster.rb worker_compute'
    puts '  ruby examples/112_multi_stage_cluster.rb worker_postprocess'
    puts

    pipeline = MultiStageCluster.new
    pipeline.run

    puts
    puts '=== Results ==='
    pipeline.results.sort_by { |r| r[:id] }.each do |r|
      puts "  Item #{r[:id]}: #{r[:result]} (status: #{r[:status]})"
    end
    puts
    puts "Total: #{pipeline.results.size} items processed"

  when 'worker_preprocess'
    puts '=== Preprocess Worker ==='
    run_preprocess_worker

  when 'worker_compute'
    puts '=== Compute Worker ==='
    run_compute_worker

  when 'worker_postprocess'
    puts '=== Postprocess Worker ==='
    run_postprocess_worker

  else
    puts "Unknown mode: #{mode}"
    puts 'Usage: ruby examples/112_multi_stage_cluster.rb [coordinator|worker_preprocess|worker_compute|worker_postprocess]'
    exit 1
  end
end
