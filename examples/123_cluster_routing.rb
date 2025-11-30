#!/usr/bin/env ruby
# frozen_string_literal: true

# Example: Cluster with Routing Strategies
#
# Demonstrates using different routing strategies with cluster execution.
# Available routing strategies:
# - :broadcast (default) - sends each item to ALL downstream stages
# - :round_robin - alternates items between downstream stages
# - :demand - routes to stage with highest demand/capacity
# - :partition - routes by hash key for partition affinity
#
# Use cases:
# - :broadcast - fan-out for parallel processing paths
# - :round_robin - load balancing across workers
# - :demand - adaptive load balancing based on capacity
# - :partition - user/key affinity for stateful processing
#
# Usage:
#   ruby examples/123_cluster_routing.rb loopback

require_relative '../lib/minigun'
require 'drb'

# Pipeline demonstrating broadcast routing after cluster
class BroadcastRoutingPipeline
  include Minigun::DSL

  attr_reader :results_a, :results_b

  def initialize(worker_uri:)
    @worker_uri = worker_uri
    @results_a = []
    @results_b = []
  end

  pipeline do
    producer :source do |output|
      5.times { |i| output << { id: i, value: i * 10 } }
    end

    in_cluster(worker_uris: [@worker_uri], shutdown_on_done: false) do
      # Broadcast: each item goes to BOTH consumers
      processor :transform, to: %i[consumer_a consumer_b] do |item, output|
        output << item
      end
    end

    consumer :consumer_a do |item|
      @results_a << item.merge(path: :a)
    end

    consumer :consumer_b do |item|
      @results_b << item.merge(path: :b)
    end
  end
end

# Pipeline demonstrating round-robin routing after cluster
class RoundRobinRoutingPipeline
  include Minigun::DSL

  attr_reader :results_a, :results_b

  def initialize(worker_uri:)
    @worker_uri = worker_uri
    @results_a = []
    @results_b = []
  end

  pipeline do
    producer :source do |output|
      10.times { |i| output << { id: i, value: i } }
    end

    in_cluster(worker_uris: [@worker_uri], shutdown_on_done: false) do
      # Round-robin: alternates between consumers
      processor :process, to: %i[worker_a worker_b], routing: :round_robin do |item, output|
        output << item
      end
    end

    consumer :worker_a do |item|
      @results_a << item.merge(assigned_to: :a)
    end

    consumer :worker_b do |item|
      @results_b << item.merge(assigned_to: :b)
    end
  end
end

# Pipeline demonstrating demand-based routing after cluster
class DemandRoutingPipeline
  include Minigun::DSL

  attr_reader :results_fast, :results_slow

  def initialize(worker_uri:)
    @worker_uri = worker_uri
    @results_fast = []
    @results_slow = []
  end

  pipeline do
    producer :source do |output|
      20.times { |i| output << { id: i, priority: rand(10) } }
    end

    in_cluster(worker_uris: [@worker_uri], shutdown_on_done: false) do
      # Demand routing: sends to consumer with most available capacity
      processor :classify, to: %i[fast_consumer slow_consumer], routing: :demand do |item, output|
        output << item.merge(classified: true)
      end
    end

    # Fast consumer with larger queue
    consumer :fast_consumer, queue_size: 10 do |item|
      @results_fast << item.merge(consumer: :fast)
    end

    # Slow consumer simulates processing delay
    consumer :slow_consumer, queue_size: 5 do |item|
      sleep 0.005
      @results_slow << item.merge(consumer: :slow)
    end
  end
end

# Pipeline demonstrating partition routing after cluster
class PartitionRoutingPipeline
  include Minigun::DSL

  attr_reader :results_a, :results_b

  def initialize(worker_uri:)
    @worker_uri = worker_uri
    @results_a = []
    @results_b = []
  end

  pipeline do
    producer :source do |output|
      # Events with user_ids - same user should go to same consumer
      [
        { user_id: 1, event: 'login' },
        { user_id: 2, event: 'view' },
        { user_id: 1, event: 'click' },
        { user_id: 3, event: 'login' },
        { user_id: 2, event: 'purchase' },
        { user_id: 1, event: 'logout' },
        { user_id: 3, event: 'view' }
      ].each { |item| output << item }
    end

    in_cluster(worker_uris: [@worker_uri], shutdown_on_done: false) do
      # Partition by user_id: same user always goes to same consumer
      processor :enrich, to: %i[partition_a partition_b], routing: :partition, partition_key: :user_id do |item, output|
        output << item.merge(enriched: true, timestamp: Time.now.to_i)
      end
    end

    consumer :partition_a do |item|
      @results_a << item
    end

    consumer :partition_b do |item|
      @results_b << item
    end
  end
end

# Pipeline demonstrating custom hash partition routing
class CustomHashRoutingPipeline
  include Minigun::DSL

  attr_reader :results

  def initialize(worker_uri:)
    @worker_uri = worker_uri
    @results = { priority_high: [], priority_medium: [], priority_low: [] }
  end

  pipeline do
    producer :source do |output|
      12.times { |i| output << { id: i, value: i * 5 } }
    end

    in_cluster(worker_uris: [@worker_uri], shutdown_on_done: false) do
      # Custom hash: route by id modulo 3 for 3-way split
      processor :route, to: %i[priority_high priority_medium priority_low],
                        routing: :partition, hash: ->(item) { item[:id] % 3 } do |item, output|
        output << item
      end
    end

    consumer :priority_high do |item|
      @results[:priority_high] << item.merge(priority: :high)
    end

    consumer :priority_medium do |item|
      @results[:priority_medium] << item.merge(priority: :medium)
    end

    consumer :priority_low do |item|
      @results[:priority_low] << item.merge(priority: :low)
    end
  end
end

# Run loopback test demonstrating all routing strategies
def run_loopback_test
  puts '=== Cluster with Routing Strategies (Loopback Test) ==='
  puts

  # Start worker
  port = 19_101
  worker = Minigun::Cluster::Worker.new(coordinator_uri: nil, worker_id: "routing-worker-#{port}")

  # Register all stage processors
  worker.register_stage(:transform) { |item, output| output.call(item.merge(transformed: true)) }
  worker.register_stage(:process) { |item, output| output.call(item.merge(processed: true)) }
  worker.register_stage(:classify) { |item, output| output.call(item.merge(classified: true)) }
  worker.register_stage(:enrich) { |item, output| output.call(item.merge(enriched: true, timestamp: Time.now.to_i)) }
  worker.register_stage(:route) { |item, output| output.call(item.merge(routed: true)) }

  service = Minigun::Cluster::WorkerService.new(worker)
  uri = "druby://127.0.0.1:#{port}"
  DRb.start_service(uri, service)
  puts "Worker started at #{uri}"
  puts

  # Test 1: Broadcast routing
  puts '--- Test 1: Broadcast Routing ---'
  broadcast = BroadcastRoutingPipeline.new(worker_uri: uri)
  broadcast.run
  puts "Results A: #{broadcast.results_a.size} items (#{broadcast.results_a.map { |r| r[:id] }.sort})"
  puts "Results B: #{broadcast.results_b.size} items (#{broadcast.results_b.map { |r| r[:id] }.sort})"
  puts "Broadcast verification: each item in BOTH consumers = #{broadcast.results_a.size == 5 && broadcast.results_b.size == 5}"
  puts

  # Test 2: Round-robin routing
  puts '--- Test 2: Round-Robin Routing ---'
  round_robin = RoundRobinRoutingPipeline.new(worker_uri: uri)
  round_robin.run
  puts "Results A: #{round_robin.results_a.size} items"
  puts "Results B: #{round_robin.results_b.size} items"
  puts "Round-robin verification: evenly distributed = #{round_robin.results_a.size == 5 && round_robin.results_b.size == 5}"
  puts

  # Test 3: Demand-based routing
  puts '--- Test 3: Demand-Based Routing ---'
  demand = DemandRoutingPipeline.new(worker_uri: uri)
  demand.run
  puts "Fast consumer: #{demand.results_fast.size} items"
  puts "Slow consumer: #{demand.results_slow.size} items"
  total = demand.results_fast.size + demand.results_slow.size
  puts "All items processed: #{total == 20}"
  puts

  # Test 4: Partition routing by key
  puts '--- Test 4: Partition Routing (by user_id) ---'
  partition = PartitionRoutingPipeline.new(worker_uri: uri)
  partition.run

  # Group by user_id to verify same user goes to same partition
  all_results = partition.results_a + partition.results_b
  user1_results = all_results.select { |r| r[:user_id] == 1 }
  user2_results = all_results.select { |r| r[:user_id] == 2 }
  user3_results = all_results.select { |r| r[:user_id] == 3 }

  puts "User 1 events: #{user1_results.map { |r| r[:event] }}"
  puts "User 2 events: #{user2_results.map { |r| r[:event] }}"
  puts "User 3 events: #{user3_results.map { |r| r[:event] }}"

  # Verify partition affinity
  user1_in_a = partition.results_a.count { |r| r[:user_id] == 1 }
  user1_in_b = partition.results_b.count { |r| r[:user_id] == 1 }
  puts "User 1 partition affinity: all in same consumer = #{user1_in_a == 3 || user1_in_b == 3}"
  puts

  # Test 5: Custom hash routing
  puts '--- Test 5: Custom Hash Routing (item[:id] % 3) ---'
  custom = CustomHashRoutingPipeline.new(worker_uri: uri)
  custom.run

  puts "Priority High (id % 3 == 0): #{custom.results[:priority_high].map { |r| r[:id] }.sort}"
  puts "Priority Medium (id % 3 == 1): #{custom.results[:priority_medium].map { |r| r[:id] }.sort}"
  puts "Priority Low (id % 3 == 2): #{custom.results[:priority_low].map { |r| r[:id] }.sort}"

  # Verify correct partitioning
  high_correct = custom.results[:priority_high].all? { |r| r[:id] % 3 == 0 }
  medium_correct = custom.results[:priority_medium].all? { |r| r[:id] % 3 == 1 }
  low_correct = custom.results[:priority_low].all? { |r| r[:id] % 3 == 2 }
  puts "Custom hash verification: all correct = #{high_correct && medium_correct && low_correct}"

  puts
  puts '=== All Routing Tests Complete ==='
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
    puts '=== Cluster with Routing Strategies Example ==='
    puts
    puts 'Demonstrates different routing strategies with cluster execution.'
    puts
    puts 'Usage:'
    puts '  ruby examples/123_cluster_routing.rb loopback'
    puts
    puts 'Routing strategies demonstrated:'
    puts '  :broadcast    - Each item to ALL downstream stages'
    puts '  :round_robin  - Alternating distribution'
    puts '  :demand       - Based on queue capacity/demand'
    puts '  :partition    - By hash key for affinity'
    puts
    puts 'Use cases:'
    puts '  - Broadcast: parallel processing paths, logging'
    puts '  - Round-robin: load balancing'
    puts '  - Demand: adaptive load balancing'
    puts '  - Partition: user session affinity, stateful processing'
  else
    puts "Unknown mode: #{mode}"
    puts 'Run with --help for usage'
    exit 1
  end
end
