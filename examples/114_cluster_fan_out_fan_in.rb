#!/usr/bin/env ruby
# frozen_string_literal: true

# Example: Cluster Fan-Out / Fan-In Pattern
#
# Demonstrates a diamond-shaped topology where work fans out to multiple
# specialized cluster pools, then fans back in for aggregation.
#
# Topology:
#
#                    Producer (local)
#                          ↓
#                     Router (local)
#                    /            \
#         Cluster A (GPU)      Cluster B (CPU)
#         Port 9000            Port 9001
#         (image tasks)        (text tasks)
#                    \            /
#                     Aggregator (local)
#                          ↓
#                    Consumer (local)
#
# Usage:
#   Terminal 1: ruby examples/114_cluster_fan_out_fan_in.rb coordinator
#   Terminal 2: ruby examples/114_cluster_fan_out_fan_in.rb worker_image
#   Terminal 3: ruby examples/114_cluster_fan_out_fan_in.rb worker_text

require_relative '../lib/minigun'

class FanOutFanInCluster
  include Minigun::DSL

  attr_reader :results

  def initialize
    @results = []
  end

  pipeline do
    # Generate mixed work items
    producer :generate do |output|
      puts '[Producer] Generating mixed tasks...'
      20.times do |i|
        task_type = i.even? ? :image : :text
        output << {
          id: i,
          type: task_type,
          data: "task-#{i}",
          value: rand(100)
        }
      end
      puts '[Producer] Generated 20 tasks (10 image, 10 text)'
    end

    # Route to appropriate cluster based on task type
    processor :route_by_type do |item, output|
      if item[:type] == :image
        output.to(:process_images) << item
      else
        output.to(:process_text) << item
      end
    end

    # Cluster A: Image processing (simulated GPU cluster)
    in_cluster(coordinator_uri: 'druby://0.0.0.0:9000', min_workers: 1, worker_timeout: 30) do
      processor :process_images do |item, output|
        # Simulate GPU-intensive image processing
        puts "  [Image Cluster] Processing image task #{item[:id]}..."
        sleep 0.15
        result = {
          id: item[:id],
          type: :image,
          result: item[:value] ** 2,
          processor: 'GPU',
          cluster: 'A'
        }
        output << result
      end
    end

    # Cluster B: Text processing (CPU cluster)
    in_cluster(coordinator_uri: 'druby://0.0.0.0:9001', min_workers: 1, worker_timeout: 30) do
      processor :process_text do |item, output|
        # Simulate CPU text processing
        puts "  [Text Cluster] Processing text task #{item[:id]}..."
        sleep 0.1
        result = {
          id: item[:id],
          type: :text,
          result: item[:data].upcase,
          processor: 'CPU',
          cluster: 'B'
        }
        output << result
      end
    end

    # Aggregate results from both clusters
    accumulator :aggregate, initial: { image: [], text: [] } do |acc, item|
      puts "[Aggregator] Received #{item[:type]} result from #{item[:cluster]}"
      acc[item[:type]] << item
      acc
    end

    # Collect final aggregated results
    consumer :collect do |aggregated|
      @results = aggregated
      puts
      puts '[Consumer] Final aggregation:'
      puts "  Image results: #{aggregated[:image].size}"
      puts "  Text results: #{aggregated[:text].size}"
    end
  end
end

# Image cluster worker (simulates GPU workers)
def run_image_worker
  worker = Minigun::Cluster::Worker.new(
    coordinator_uri: 'druby://127.0.0.1:9000',
    worker_id: "image-worker-#{Process.pid}"
  )

  worker.register_stage(:process_images) do |item, output|
    puts "  [Image Worker #{Process.pid}] Processing #{item[:id]}..."
    sleep 0.15
    result = {
      id: item[:id],
      type: :image,
      result: item[:value] ** 2,
      processor: 'GPU',
      cluster: 'A'
    }
    output.call(result)
  end

  worker.connect
  puts "Image worker #{worker.worker_id} connected (simulating GPU)!"
  worker.start
end

# Text cluster worker (CPU workers)
def run_text_worker
  worker = Minigun::Cluster::Worker.new(
    coordinator_uri: 'druby://127.0.0.1:9001',
    worker_id: "text-worker-#{Process.pid}"
  )

  worker.register_stage(:process_text) do |item, output|
    puts "  [Text Worker #{Process.pid}] Processing #{item[:id]}..."
    sleep 0.1
    result = {
      id: item[:id],
      type: :text,
      result: item[:data].upcase,
      processor: 'CPU',
      cluster: 'B'
    }
    output.call(result)
  end

  worker.connect
  puts "Text worker #{worker.worker_id} connected!"
  worker.start
end

# Main execution
if __FILE__ == $PROGRAM_NAME
  Minigun.logger.level = Logger::INFO

  mode = ARGV[0] || 'coordinator'

  case mode
  when 'coordinator'
    puts '=== Fan-Out / Fan-In Cluster Pipeline ==='
    puts
    puts 'This demonstrates routing to specialized clusters:'
    puts '  - Image tasks → GPU Cluster (port 9000)'
    puts '  - Text tasks  → CPU Cluster (port 9001)'
    puts
    puts 'Start workers in separate terminals:'
    puts '  ruby examples/114_cluster_fan_out_fan_in.rb worker_image'
    puts '  ruby examples/114_cluster_fan_out_fan_in.rb worker_text'
    puts

    pipeline = FanOutFanInCluster.new
    pipeline.run

    puts
    puts '=== Results Summary ==='
    puts
    puts 'Image Results (GPU Cluster):'
    pipeline.results[:image].sort_by { |r| r[:id] }.each do |r|
      puts "  Task #{r[:id]}: #{r[:result]} (#{r[:processor]})"
    end
    puts
    puts 'Text Results (CPU Cluster):'
    pipeline.results[:text].sort_by { |r| r[:id] }.each do |r|
      puts "  Task #{r[:id]}: #{r[:result]} (#{r[:processor]})"
    end
    puts
    puts "Total: #{pipeline.results[:image].size} image + #{pipeline.results[:text].size} text = #{pipeline.results[:image].size + pipeline.results[:text].size} tasks"

  when 'worker_image'
    puts '=== Image Worker (GPU Simulator) ==='
    run_image_worker

  when 'worker_text'
    puts '=== Text Worker ==='
    run_text_worker

  else
    puts "Unknown mode: #{mode}"
    puts 'Usage: ruby examples/114_cluster_fan_out_fan_in.rb [coordinator|worker_image|worker_text]'
    exit 1
  end
end
