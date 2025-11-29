#!/usr/bin/env ruby
# frozen_string_literal: true

# Example: Peer-to-Peer Cluster Communication
#
# Demonstrates cluster workers communicating with each other peer-to-peer,
# not just through the coordinator. Useful for data-intensive workflows where
# workers need to share large intermediate results.
#
# Topology:
#
#   Coordinator (port 9000)
#        ↓
#   Worker A (owns data shard 0-4)  ←→  Worker B (owns data shard 5-9)
#        ↓                                    ↓
#   Workers can request data from each other directly
#   bypassing coordinator for large data transfers
#
# Usage:
#   Terminal 1: ruby examples/116_peer_to_peer_cluster.rb coordinator
#   Terminal 2: ruby examples/116_peer_to_peer_cluster.rb worker 0 9010
#   Terminal 3: ruby examples/116_peer_to_peer_cluster.rb worker 5 9011

require_relative '../lib/minigun'
require 'drb'

# Shared data store accessible via DRb
class DataShard
  def initialize(shard_id, start_id, end_id)
    @shard_id = shard_id
    @data = {}
    # Pre-populate shard with data
    (start_id..end_id).each do |i|
      @data[i] = { id: i, value: rand(1000), shard: shard_id }
    end
  end

  def get(id)
    @data[id]
  end

  def keys
    @data.keys
  end

  def size
    @data.size
  end

  def shard_id
    @shard_id
  end
end

class PeerToPeerPipeline
  include Minigun::DSL

  attr_reader :results

  def initialize
    @results = []
  end

  pipeline do
    # Generate join tasks that require data from multiple shards
    producer :generate_join_tasks do |output|
      puts '[Producer] Generating join tasks...'
      # Each task needs to join data from two shards
      10.times do |i|
        left_id = i
        right_id = 9 - i # Ensures cross-shard joins
        output << { task_id: i, left_id: left_id, right_id: right_id }
      end
      puts '[Producer] Generated 10 join tasks'
    end

    # Cluster workers perform joins by fetching data peer-to-peer
    in_cluster(coordinator: 'druby://0.0.0.0:9000', min_workers: 2, worker_timeout: 30) do
      processor :distributed_join do |task, output|
        # Worker will fetch data from peers if needed
        # (Implemented in worker code below)
        output << task
      end
    end

    consumer :collect do |result|
      @results << result
      if result[:error]
        puts "[Consumer] Task #{result[:task_id]}: ERROR - #{result[:error]}"
      else
        puts "[Consumer] Task #{result[:task_id]}: Joined #{result[:left_value]} + #{result[:right_value]} = #{result[:result]}"
      end
    end
  end
end

# Worker with peer-to-peer data sharing
def run_worker(shard_start, worker_port)
  # Determine shard range
  shard_end = shard_start + 4
  shard_id = shard_start / 5

  # Create data shard
  shard = DataShard.new(shard_id, shard_start, shard_end)

  # Start DRb service to expose shard to peers
  DRb.start_service("druby://0.0.0.0:#{worker_port}", shard)
  my_uri = "druby://127.0.0.1:#{worker_port}"

  puts "Worker shard #{shard_id} started at #{my_uri}"
  puts "  Owns data IDs: #{shard_start}-#{shard_end}"

  # Create worker
  worker = Minigun::Cluster::Worker.new(
    coordinator_uri: 'druby://127.0.0.1:9000',
    worker_id: "worker-shard-#{shard_id}"
  )

  # Register distributed join processor
  worker.register_stage(:distributed_join) do |task, output|
    puts "  [Worker #{shard_id}] Processing join task #{task[:task_id]}: #{task[:left_id]} ⋈ #{task[:right_id]}"

    begin
      # Fetch left data (might be local or from peer)
      left_data = if shard.keys.include?(task[:left_id])
                    puts "    [Worker #{shard_id}] Left data #{task[:left_id]} is LOCAL"
                    shard.get(task[:left_id])
                  else
                    # Fetch from peer
                    peer_port = task[:left_id] < 5 ? 9010 : 9011
                    puts "    [Worker #{shard_id}] Fetching left data #{task[:left_id]} from PEER on port #{peer_port}"
                    peer_shard = DRbObject.new_with_uri("druby://127.0.0.1:#{peer_port}")
                    peer_shard.get(task[:left_id])
                  end

      # Fetch right data (might be local or from peer)
      right_data = if shard.keys.include?(task[:right_id])
                     puts "    [Worker #{shard_id}] Right data #{task[:right_id]} is LOCAL"
                     shard.get(task[:right_id])
                   else
                     # Fetch from peer
                     peer_port = task[:right_id] < 5 ? 9010 : 9011
                     puts "    [Worker #{shard_id}] Fetching right data #{task[:right_id]} from PEER on port #{peer_port}"
                     peer_shard = DRbObject.new_with_uri("druby://127.0.0.1:#{peer_port}")
                     peer_shard.get(task[:right_id])
                   end

      # Perform join computation
      result_value = left_data[:value] + right_data[:value]

      output.call({
        task_id: task[:task_id],
        left_id: task[:left_id],
        right_id: task[:right_id],
        left_value: left_data[:value],
        right_value: right_data[:value],
        result: result_value,
        worker_shard: shard_id
      })
    rescue StandardError => e
      puts "    [Worker #{shard_id}] ERROR: #{e.message}"
      output.call({
        task_id: task[:task_id],
        error: e.message,
        worker_shard: shard_id
      })
    end
  end

  worker.connect
  puts "Worker shard #{shard_id} connected to coordinator!"
  puts 'Processing join tasks...'
  worker.start
end

# Main execution
if __FILE__ == $PROGRAM_NAME
  Minigun.logger.level = Logger::INFO

  mode = ARGV[0] || 'coordinator'

  case mode
  when 'coordinator'
    puts '=== Peer-to-Peer Cluster Pipeline ==='
    puts
    puts 'This demonstrates workers communicating peer-to-peer:'
    puts '  - Worker A owns data IDs 0-4 (port 9010)'
    puts '  - Worker B owns data IDs 5-9 (port 9011)'
    puts '  - Workers fetch data from each other directly'
    puts '  - Coordinator only distributes join tasks'
    puts
    puts 'Start workers in separate terminals:'
    puts '  ruby examples/116_peer_to_peer_cluster.rb worker 0 9010'
    puts '  ruby examples/116_peer_to_peer_cluster.rb worker 5 9011'
    puts

    pipeline = PeerToPeerPipeline.new
    pipeline.run

    puts
    puts '=== Results Summary ==='
    successful = pipeline.results.reject { |r| r[:error] }
    failed = pipeline.results.select { |r| r[:error] }

    puts "Total tasks: #{pipeline.results.size}"
    puts "Successful: #{successful.size}"
    puts "Failed: #{failed.size}"
    puts
    if successful.any?
      puts 'Sample successful joins:'
      successful.first(5).each do |r|
        puts "  Task #{r[:task_id]}: #{r[:left_value]} + #{r[:right_value]} = #{r[:result]} (worker: shard #{r[:worker_shard]})"
      end
    end

  when 'worker'
    shard_start = ARGV[1]&.to_i
    worker_port = ARGV[2]&.to_i

    unless shard_start && worker_port
      puts 'ERROR: Both shard_start and worker_port required'
      puts 'Usage: ruby examples/116_peer_to_peer_cluster.rb worker SHARD_START PORT'
      puts 'Examples:'
      puts '  ruby examples/116_peer_to_peer_cluster.rb worker 0 9010  # Shard 0 (IDs 0-4)'
      puts '  ruby examples/116_peer_to_peer_cluster.rb worker 5 9011  # Shard 1 (IDs 5-9)'
      exit 1
    end

    puts "=== Worker (Shard starting at #{shard_start}, Port #{worker_port}) ==="
    run_worker(shard_start, worker_port)

  else
    puts "Unknown mode: #{mode}"
    puts 'Usage: ruby examples/116_peer_to_peer_cluster.rb [coordinator|worker SHARD_START PORT]'
    exit 1
  end
end
