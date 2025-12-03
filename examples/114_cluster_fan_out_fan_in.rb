#!/usr/bin/env ruby
# frozen_string_literal: true

# Example: Cluster with Specialized Workers
#
# Demonstrates routing different task types to specialized workers within
# the same cluster. Uses a single cluster where workers process different
# task types based on their capabilities.
#
# Topology:
#
#   Producer (local)
#        ↓
#   Cluster (port 9000)
#   - Image workers process :image tasks
#   - Text workers process :text tasks
#        ↓
#   Consumer (local)
#
# Usage:
#   Terminal 1: ruby examples/114_cluster_fan_out_fan_in.rb coordinator
#   Terminal 2: ruby examples/114_cluster_fan_out_fan_in.rb worker_image
#   Terminal 3: ruby examples/114_cluster_fan_out_fan_in.rb worker_text

require_relative '../lib/minigun'

# Force unbuffered output for test harness compatibility
$stdout.sync = true
$stderr.sync = true

# Configuration via environment variables for testing
CLUSTER_PORT = ENV.fetch('CLUSTER_PORT', '9000').to_i
WORKER_TIMEOUT = ENV.fetch('WORKER_TIMEOUT', '30').to_i

# Specialized workers cluster example
class SpecializedWorkersCluster
  def self.create_pipeline(port)
    Class.new do
      include Minigun::DSL

      attr_reader :results

      define_method(:initialize) do
        @results = { image: [], text: [] }
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

        # Single cluster with specialized workers
        # Workers register for :process_mixed and handle based on item type
        in_cluster(coordinator_uri: "druby://0.0.0.0:#{port}", min_workers: 2, worker_timeout: WORKER_TIMEOUT) do
          processor :process_mixed do |item, output|
            # This block defines the interface, actual processing happens on workers
            output << item
          end
        end

        # Collect and aggregate results
        consumer :collect do |item|
          puts "[Collector] Received #{item[:type]} result: #{item[:result]}"
          @results[item[:type]] << item
        end
      end
    end.new
  end
end

# Image worker (processes image-type tasks)
def run_image_worker(port = CLUSTER_PORT)
  worker = Minigun::Cluster::Worker.new(
    coordinator_uri: "druby://127.0.0.1:#{port}",
    worker_id: "image-worker-#{Process.pid}"
  )

  worker.register_stage(:process_mixed) do |item, output|
    if item[:type] == :image
      puts "  [Image Worker #{Process.pid}] Processing image task #{item[:id]}..."
      sleep 0.1
      result = {
        id: item[:id],
        type: :image,
        result: item[:value]**2,
        processor: 'GPU',
        original_data: item[:data]
      }
      output.call(result)
    else
      # Re-queue non-image items for another worker
      puts "  [Image Worker #{Process.pid}] Skipping non-image task #{item[:id]}"
      # For this example, we'll process anyway to avoid deadlock
      result = {
        id: item[:id],
        type: item[:type],
        result: item[:data].upcase,
        processor: 'CPU-fallback',
        original_data: item[:data]
      }
      output.call(result)
    end
  end

  worker.connect
  puts "Image worker #{worker.worker_id} connected (GPU simulator)!"
  worker.start
end

# Text worker (processes text-type tasks)
def run_text_worker(port = CLUSTER_PORT)
  worker = Minigun::Cluster::Worker.new(
    coordinator_uri: "druby://127.0.0.1:#{port}",
    worker_id: "text-worker-#{Process.pid}"
  )

  worker.register_stage(:process_mixed) do |item, output|
    if item[:type] == :text
      puts "  [Text Worker #{Process.pid}] Processing text task #{item[:id]}..."
      sleep 0.1
      result = {
        id: item[:id],
        type: :text,
        result: item[:data].upcase,
        processor: 'CPU',
        original_data: item[:data]
      }
      output.call(result)
    else
      # Process image items too (fallback)
      puts "  [Text Worker #{Process.pid}] Processing image task #{item[:id]} (fallback)..."
      result = {
        id: item[:id],
        type: :image,
        result: item[:value]**2,
        processor: 'CPU-fallback',
        original_data: item[:data]
      }
      output.call(result)
    end
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
    puts '=== Specialized Workers Cluster Pipeline ==='
    puts
    puts 'This demonstrates a cluster with specialized workers:'
    puts '  - Image workers prefer image tasks (GPU simulation)'
    puts '  - Text workers prefer text tasks (CPU)'
    puts '  - Both can handle any task type as fallback'
    puts
    puts 'Start workers in separate terminals:'
    puts '  ruby examples/114_cluster_fan_out_fan_in.rb worker_image'
    puts '  ruby examples/114_cluster_fan_out_fan_in.rb worker_text'
    puts

    pipeline = SpecializedWorkersCluster.create_pipeline(CLUSTER_PORT)
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
    image_count = pipeline.results[:image].size
    text_count = pipeline.results[:text].size
    puts "Total: #{image_count} image + #{text_count} text = #{image_count + text_count} tasks"

  when 'worker_image'
    puts '=== Image Worker (GPU Simulator) ==='
    run_image_worker(CLUSTER_PORT)

  when 'worker_text'
    puts '=== Text Worker ==='
    run_text_worker(CLUSTER_PORT)

  else
    puts "Unknown mode: #{mode}"
    puts 'Usage: ruby examples/114_cluster_fan_out_fan_in.rb [coordinator|worker_image|worker_text]'
    exit 1
  end
end
