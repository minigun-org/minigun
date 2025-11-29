#!/usr/bin/env ruby
# frozen_string_literal: true

# Example: Cluster Direct Mode with shutdown_on_done
#
# Demonstrates the shutdown_on_done option for direct mode cluster execution.
# When shutdown_on_done: true, workers are sent a shutdown signal after the
# pipeline stage completes. This is useful for dedicated workers that should
# terminate after processing a specific job.
#
# Use cases:
# - One-time batch jobs where workers should exit after completion
# - Ephemeral workers (e.g., cloud spot instances that should terminate)
# - Testing and development (auto-cleanup)
#
# Comparison:
# - shutdown_on_done: false (default) - Workers stay running for more work
# - shutdown_on_done: true - Workers shutdown after this pipeline completes
#
# Topology:
#
#   Producer (local)
#        |
#   [shutdown_on_done: true]
#        |
#   +----+----+----+
#   |    |    |    |
#   W1   W2   W3   W4  (dedicated workers, will shutdown after job)
#   |    |    |    |
#   +----+----+----+
#        |
#   Consumer (local)
#        |
#   Workers receive shutdown signal
#
# Usage:
#   # Multi-terminal (workers stay until shutdown signal):
#   Terminal 1: ruby examples/119_cluster_shutdown_on_done.rb worker 9001
#   Terminal 2: ruby examples/119_cluster_shutdown_on_done.rb worker 9002
#   Terminal 3: ruby examples/119_cluster_shutdown_on_done.rb client
#   # After client completes, workers will automatically exit
#
#   # Single-process loopback test:
#   ruby examples/119_cluster_shutdown_on_done.rb loopback

require_relative '../lib/minigun'
require 'drb'

# Pipeline that uses shutdown_on_done to terminate workers after completion
class ShutdownOnDonePipeline
  include Minigun::DSL

  attr_reader :results

  def initialize(worker_uris:, shutdown_on_done: true)
    @worker_uris = worker_uris
    @shutdown_on_done = shutdown_on_done
    @results = []
  end

  pipeline do
    producer :generate do |output|
      puts '[Producer] Generating batch job items...'
      20.times do |i|
        output << { id: i, value: rand(1000), batch_id: 'JOB-001' }
      end
      puts '[Producer] Generated 20 items for batch JOB-001'
    end

    # Direct mode with shutdown_on_done
    # When true, workers will receive shutdown signal after this stage completes
    in_cluster(worker_uris: @worker_uris, shutdown_on_done: @shutdown_on_done) do
      processor :process_batch do |item, output|
        # Simulate batch processing work
        result = (1..1000).reduce(item[:value]) { |acc, _| Math.sqrt(acc.abs + 1) }
        output << {
          id: item[:id],
          batch_id: item[:batch_id],
          original: item[:value],
          computed: result.round(4)
        }
      end
    end

    consumer :collect do |item|
      @results << item
      puts "[Consumer] Collected result #{item[:id]} from batch #{item[:batch_id]}"
    end
  end
end

# Worker that tracks shutdown signals
class DedicatedWorker
  attr_reader :shutdown_received, :items_processed

  def initialize(port)
    @port = port
    @shutdown_received = false
    @items_processed = 0
    @mutex = Mutex.new
  end

  def start
    worker = Minigun::Cluster::Worker.new(
      coordinator_uri: nil,
      worker_id: "dedicated-worker-#{@port}"
    )

    worker.register_stage(:process_batch) do |item, output|
      @mutex.synchronize { @items_processed += 1 }
      puts "[Worker #{@port}] Processing item #{item[:id]} (total: #{@items_processed})"

      result = (1..1000).reduce(item[:value]) { |acc, _| Math.sqrt(acc.abs + 1) }
      output.call(
        {
          id: item[:id],
          batch_id: item[:batch_id],
          original: item[:value],
          computed: result.round(4),
          worker: @port
        }
      )
    end

    # Create service with shutdown tracking
    service = TrackingWorkerService.new(worker, self)
    DRb.start_service("druby://0.0.0.0:#{@port}", service)

    puts "[Worker #{@port}] Started - waiting for work"
    puts "[Worker #{@port}] Will shutdown when client sends shutdown signal"

    # Wait for shutdown
    DRb.thread.join
  end

  def mark_shutdown
    @shutdown_received = true
    puts "[Worker #{@port}] SHUTDOWN RECEIVED after processing #{@items_processed} items"
    # Stop DRb service to exit
    Thread.new do
      sleep 0.1
      DRb.stop_service
    end
  end
end

# Extended WorkerService that tracks shutdown signals
class TrackingWorkerService < Minigun::Cluster::WorkerService
  def initialize(worker, dedicated_worker)
    super(worker)
    @dedicated_worker = dedicated_worker
  end

  def shutdown
    @dedicated_worker.mark_shutdown
    super
  end
end

# Run loopback test demonstrating shutdown_on_done
def run_loopback_test
  puts '=== Loopback Test: shutdown_on_done ==='
  puts
  puts 'This test demonstrates that workers receive shutdown signals'
  puts 'when the pipeline completes with shutdown_on_done: true'
  puts

  workers = []
  services = []
  worker_uris = []
  shutdown_flags = []

  # Start 3 workers
  [9101, 9102, 9103].each do |port|
    worker = Minigun::Cluster::Worker.new(
      coordinator_uri: nil,
      worker_id: "loopback-worker-#{port}"
    )

    shutdown_flag = { received: false, items: 0, port: port }
    shutdown_flags << shutdown_flag

    worker.register_stage(:process_batch) do |item, output|
      shutdown_flag[:items] += 1
      puts "  [Worker #{port}] Processing item #{item[:id]} (count: #{shutdown_flag[:items]})"
      result = (1..500).reduce(item[:value]) { |acc, _| Math.sqrt(acc.abs + 1) }
      output.call({
                    id: item[:id],
                    batch_id: item[:batch_id],
                    original: item[:value],
                    computed: result.round(4),
                    worker: port
                  })
    end

    # Create tracking service
    service = Object.new
    service.define_singleton_method(:ping) { :pong }
    service.define_singleton_method(:process_item) do |stage_name, item|
      worker.process_item_sync(stage_name, item)
    end
    service.define_singleton_method(:shutdown) do
      shutdown_flag[:received] = true
      puts "  [Worker #{port}] SHUTDOWN signal received!"
    end

    uri = "druby://127.0.0.1:#{port}"
    DRb.start_service(uri, service)

    workers << worker
    services << service
    worker_uris << uri

    puts "  Worker started at #{uri}"
  end

  puts
  puts '--- Running pipeline with shutdown_on_done: true ---'
  puts

  pipeline = ShutdownOnDonePipeline.new(worker_uris: worker_uris, shutdown_on_done: true)
  pipeline.run

  # Give shutdown signals time to propagate
  sleep 0.2

  puts
  puts '=== Shutdown Status ==='
  shutdown_flags.each do |flag|
    status = flag[:received] ? 'YES' : 'NO'
    puts "  Worker #{flag[:port]}: shutdown received = #{status}, items processed = #{flag[:items]}"
  end

  all_received = shutdown_flags.all? { |f| f[:received] }
  puts
  if all_received
    puts 'SUCCESS: All workers received shutdown signal!'
  else
    puts 'WARNING: Not all workers received shutdown signal'
  end

  puts
  puts '=== Results ==='
  puts "Total items processed: #{pipeline.results.size}"

  # Show work distribution
  by_worker = pipeline.results.group_by { |r| r[:worker] }
  puts
  puts 'Work distribution:'
  by_worker.each do |worker, items|
    puts "  Worker #{worker}: #{items.size} items"
  end

  puts
  puts '--- Now testing with shutdown_on_done: false ---'
  puts

  # Reset shutdown flags
  shutdown_flags.each do |f|
    f[:received] = false
    f[:items] = 0
  end

  pipeline2 = ShutdownOnDonePipeline.new(worker_uris: worker_uris, shutdown_on_done: false)
  pipeline2.run

  sleep 0.2

  puts
  puts '=== Shutdown Status (shutdown_on_done: false) ==='
  shutdown_flags.each do |flag|
    status = flag[:received] ? 'YES' : 'NO'
    puts "  Worker #{flag[:port]}: shutdown received = #{status}, items processed = #{flag[:items]}"
  end

  none_received = shutdown_flags.none? { |f| f[:received] }
  puts
  if none_received
    puts 'SUCCESS: No workers received shutdown (as expected with shutdown_on_done: false)'
  else
    puts 'WARNING: Some workers received unexpected shutdown'
  end

  puts
  puts "Total items processed in second run: #{pipeline2.results.size}"
rescue StandardError => e
  puts "Error: #{e.message}"
  puts e.backtrace.first(5).join("\n")
ensure
  DRb.stop_service
end

# Run multi-terminal worker
def run_worker(port)
  puts "=== Dedicated Worker (Port #{port}) ==="
  puts
  puts 'This worker will automatically shutdown when the client pipeline completes'
  puts '(if the client uses shutdown_on_done: true)'
  puts
  puts 'Press Ctrl+C to manually stop'
  puts

  worker = DedicatedWorker.new(port)
  worker.start

  puts
  puts '=== Worker Summary ==='
  puts "  Shutdown signal received: #{worker.shutdown_received}"
  puts "  Items processed: #{worker.items_processed}"
rescue Interrupt
  puts "\nManually interrupted"
  DRb.stop_service
end

# Run client
def run_client(shutdown_on_done)
  puts '=== Batch Job Client ==='
  puts
  puts "shutdown_on_done: #{shutdown_on_done}"
  puts
  puts 'Make sure workers are running:'
  puts '  ruby examples/119_cluster_shutdown_on_done.rb worker 9001'
  puts '  ruby examples/119_cluster_shutdown_on_done.rb worker 9002'
  puts

  worker_uris = [
    'druby://127.0.0.1:9001',
    'druby://127.0.0.1:9002'
  ]

  DRb.start_service

  pipeline = ShutdownOnDonePipeline.new(
    worker_uris: worker_uris,
    shutdown_on_done: shutdown_on_done
  )

  begin
    pipeline.run

    puts
    puts '=== Results ==='
    puts "Total: #{pipeline.results.size} items processed"

    puts
    if shutdown_on_done
      puts 'Workers should have received shutdown signal and exited.'
      puts 'Check worker terminals to confirm.'
    else
      puts 'Workers are still running (shutdown_on_done: false).'
      puts 'They can process more work from other clients.'
    end
  rescue Minigun::Cluster::Error => e
    puts "Cluster error: #{e.message}"
    puts 'Make sure workers are running!'
  end
end

# Main execution
if __FILE__ == $PROGRAM_NAME
  Minigun.logger.level = Logger::INFO

  mode = ARGV[0] || 'help'

  case mode
  when 'worker'
    port = ARGV[1]&.to_i
    unless port
      puts 'ERROR: Port required for worker'
      puts 'Usage: ruby examples/119_cluster_shutdown_on_done.rb worker PORT'
      exit 1
    end
    run_worker(port)

  when 'client'
    # Default to shutdown_on_done: true for demonstration
    shutdown_on_done = ARGV[1] != 'false'
    run_client(shutdown_on_done)

  when 'client-keep-alive'
    # Explicitly keep workers alive
    run_client(false)

  when 'loopback'
    run_loopback_test

  when 'help', '--help', '-h'
    puts '=== Cluster shutdown_on_done Example ==='
    puts
    puts 'Demonstrates the shutdown_on_done option for direct mode.'
    puts 'When true, workers receive shutdown signal after pipeline completes.'
    puts
    puts 'Usage:'
    puts '  worker PORT       - Start a dedicated worker on PORT'
    puts '  client            - Run pipeline with shutdown_on_done: true'
    puts '  client-keep-alive - Run pipeline with shutdown_on_done: false'
    puts '  loopback          - Run self-contained test (all in one process)'
    puts
    puts 'Multi-terminal setup:'
    puts '  Terminal 1: ruby examples/119_cluster_shutdown_on_done.rb worker 9001'
    puts '  Terminal 2: ruby examples/119_cluster_shutdown_on_done.rb worker 9002'
    puts '  Terminal 3: ruby examples/119_cluster_shutdown_on_done.rb client'
    puts '  # After client completes, workers will exit automatically'
    puts
    puts 'Single-process test:'
    puts '  ruby examples/119_cluster_shutdown_on_done.rb loopback'

  else
    puts "Unknown mode: #{mode}"
    puts 'Run with --help for usage'
    exit 1
  end
end
