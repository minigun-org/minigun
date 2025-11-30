#!/usr/bin/env ruby
# frozen_string_literal: true

# Example: Cluster with Demand-Based Backpressure
#
# Demonstrates using cluster execution with demand settings.
# Demand settings (min_demand, max_demand) control backpressure:
# - When pending demand drops below min_demand, consumer requests more
# - Consumer requests enough to bring demand up to max_demand
# - This creates batches of (max_demand - min_demand) items
#
# Use cases:
# - Memory-constrained workers
# - Rate-limiting distributed processing
# - Preventing producer from overwhelming slow cluster workers
#
# Topology:
#
#   Producer (with demand throttling)
#        |
#   Cluster Stage (distributed)
#        |
#   Consumer (with custom demand settings)
#
# Usage:
#   ruby examples/122_cluster_demand.rb loopback

require_relative '../lib/minigun'
require 'drb'

# Pipeline that uses demand-based backpressure with cluster
class ClusterDemandPipeline
  include Minigun::DSL

  attr_reader :results, :processed_count

  def initialize(worker_uris:)
    @worker_uris = worker_uris
    @results = []
    @processed_count = Concurrent::AtomicFixnum.new(0)
  end

  # Enable demand-based backpressure for the entire pipeline
  pipeline demand: true do
    # Producer with custom demand settings
    producer :generate, min_demand: 10, max_demand: 25 do |output|
      puts '[Producer] Generating work items with demand backpressure...'
      50.times do |i|
        output << { id: i, value: rand(100) }
      end
      puts '[Producer] Generated 50 work items'
    end

    # Cluster stage for distributed processing
    in_cluster(worker_uris: @worker_uris, shutdown_on_done: false) do
      processor :compute do |item, output|
        # Simulate computation
        result = (1..2000).reduce(item[:value]) { |acc, _| Math.sqrt(acc.abs + 1) }
        @processed_count.increment
        output << { id: item[:id], original: item[:value], computed: result.round(4) }
      end
    end

    # Consumer with tight demand settings (small buffer)
    consumer :collect, min_demand: 3, max_demand: 8 do |item|
      @results << item
    end
  end
end

# Pipeline demonstrating multiple stages with different demand settings
class MultiStageDemandPipeline
  include Minigun::DSL

  attr_reader :results

  def initialize(worker_uris:)
    @worker_uris = worker_uris
    @results = []
  end

  pipeline demand: true do
    # Source with large demand buffer (producer-friendly)
    producer :source, min_demand: 50, max_demand: 100 do |output|
      puts '[Source] Producing items with large demand buffer...'
      30.times { |i| output << i }
      puts '[Source] Done producing'
    end

    # Cluster stage processes items
    in_cluster(worker_uris: @worker_uris, shutdown_on_done: false) do
      processor :transform do |item, output|
        output << { value: item * 2, stage: :transform }
      end
    end

    # Middle stage with medium demand settings
    consumer :enrich, min_demand: 10, max_demand: 20 do |item, output|
      output << item.merge(enriched: true)
    end

    # Final consumer with very small demand (tight backpressure)
    consumer :sink, min_demand: 2, max_demand: 5 do |item|
      @results << item
    end
  end
end

# Run loopback test
def run_loopback_test
  puts '=== Cluster with Demand Backpressure (Loopback Test) ==='
  puts

  workers = []
  started_services = []
  worker_uris = []

  # Start workers
  [19_001, 19_002].each do |port|
    worker = Minigun::Cluster::Worker.new(
      coordinator_uri: nil,
      worker_id: "demand-worker-#{port}"
    )

    worker.register_stage(:compute) do |item, output|
      result = (1..2000).reduce(item[:value]) { |acc, _| Math.sqrt(acc.abs + 1) }
      output.call({ id: item[:id], original: item[:value], computed: result.round(4), worker: port })
    end

    worker.register_stage(:transform) do |item, output|
      output.call({ value: item * 2, stage: :transform, worker: port })
    end

    service = Minigun::Cluster::WorkerService.new(worker)
    uri = "druby://127.0.0.1:#{port}"
    DRb.start_service(uri, service)

    workers << worker
    started_services << uri
    worker_uris << uri
    puts "  Worker started at #{uri}"
  end

  puts
  puts '--- Running ClusterDemandPipeline ---'
  puts

  pipeline1 = ClusterDemandPipeline.new(worker_uris: worker_uris)
  pipeline1.run

  puts
  puts "Processed #{pipeline1.results.size} items with demand backpressure"
  puts "Sample results: #{pipeline1.results.take(3).inspect}"
  puts

  # Verify work distribution
  worker_counts = pipeline1.results.group_by { |r| r[:worker] }.transform_values(&:size)
  puts 'Work distribution:'
  worker_counts.each { |w, c| puts "  Worker #{w}: #{c} items" }

  puts
  puts '--- Running MultiStageDemandPipeline ---'
  puts

  pipeline2 = MultiStageDemandPipeline.new(worker_uris: worker_uris)
  pipeline2.run

  puts
  puts "Multi-stage processed #{pipeline2.results.size} items"
  puts "All items enriched: #{pipeline2.results.all? { |r| r[:enriched] }}"
  puts "Sample result: #{pipeline2.results.first.inspect}"

  puts
  puts '=== Test Complete ==='
rescue StandardError => e
  puts "Error: #{e.message}"
  puts e.backtrace.first(5).join("\n")
ensure
  DRb.stop_service
end

# Main execution
if __FILE__ == $PROGRAM_NAME
  Minigun.logger.level = Logger::WARN

  mode = ARGV[0] || 'loopback'

  case mode
  when 'loopback'
    run_loopback_test
  when 'help', '--help', '-h'
    puts '=== Cluster with Demand Example ==='
    puts
    puts 'Demonstrates cluster execution with demand-based backpressure.'
    puts
    puts 'Usage:'
    puts '  ruby examples/122_cluster_demand.rb loopback'
    puts
    puts 'Features demonstrated:'
    puts '  - demand: true pipeline option'
    puts '  - min_demand / max_demand per-stage settings'
    puts '  - Tight backpressure with small demand buffers'
    puts '  - Multi-stage demand configuration'
  else
    puts "Unknown mode: #{mode}"
    puts 'Run with --help for usage'
    exit 1
  end
end
