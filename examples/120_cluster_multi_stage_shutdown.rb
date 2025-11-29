#!/usr/bin/env ruby
# frozen_string_literal: true

# Example: Multi-Stage Cluster with Mixed Shutdown Behavior
#
# Demonstrates a pipeline with multiple cluster stages where different stages
# have different shutdown_on_done settings. This is useful when:
#
# - Stage 1 workers are from a shared pool (keep alive)
# - Stage 2 workers are dedicated/ephemeral (shutdown after use)
#
# Use cases:
# - Preprocessing on shared infrastructure, heavy compute on spot instances
# - Validation on shared validators, processing on dedicated workers
# - Mixing long-running services with one-time batch workers
#
# Topology:
#
#   Producer (local)
#        |
#   +----+----+----+
#   | Stage 1: validate (shared workers, shutdown_on_done: false)
#   |    W1   W2   W3  (stay running)
#   +----+----+----+
#        |
#   +----+----+----+
#   | Stage 2: process (dedicated workers, shutdown_on_done: true)
#   |    W4   W5   W6  (will shutdown)
#   +----+----+----+
#        |
#   Consumer (local)
#
# Usage:
#   ruby examples/120_cluster_multi_stage_shutdown.rb loopback

require_relative '../lib/minigun'
require 'drb'

# Pipeline with two cluster stages having different shutdown behaviors
class MultiStageShutdownPipeline
  include Minigun::DSL

  attr_reader :results

  def initialize(validator_uris:, processor_uris:)
    @validator_uris = validator_uris
    @processor_uris = processor_uris
    @results = []
  end

  pipeline do
    producer :generate do |output|
      puts '[Producer] Generating work items...'
      12.times do |i|
        output << { id: i, data: "item-#{i}", value: rand(100) }
      end
      puts '[Producer] Generated 12 items'
    end

    # Stage 1: Validation on shared workers (don't shutdown)
    # These workers are part of a shared pool serving multiple clients
    in_cluster(worker_uris: @validator_uris, shutdown_on_done: false) do
      processor :validate do |item, output|
        # Simulate validation
        validated = item.merge(
          validated: true,
          validation_time: Time.now.to_f
        )
        output << validated
      end
    end

    # Stage 2: Heavy processing on dedicated workers (shutdown when done)
    # These workers are dedicated to this job and should terminate after
    in_cluster(worker_uris: @processor_uris, shutdown_on_done: true) do
      processor :process do |item, output|
        # Simulate heavy processing
        result = (1..2000).reduce(item[:value]) { |acc, _| Math.sqrt(acc.abs + 1) }
        processed = item.merge(
          processed: true,
          computed: result.round(4),
          processing_time: Time.now.to_f
        )
        output << processed
      end
    end

    consumer :collect do |item|
      @results << item
      puts "[Consumer] Collected item #{item[:id]} (validated: #{item[:validated]}, processed: #{item[:processed]})"
    end
  end
end

# Run loopback test demonstrating mixed shutdown behavior
def run_loopback_test
  puts '=== Multi-Stage Shutdown Test ==='
  puts
  puts 'This test demonstrates:'
  puts '  - Stage 1 (validate): shutdown_on_done: false - workers stay running'
  puts '  - Stage 2 (process): shutdown_on_done: true - workers shutdown after'
  puts

  # Track shutdown state for each worker
  validator_flags = []
  processor_flags = []

  # Start validator workers (shared pool - should NOT shutdown)
  validator_uris = []
  [9201, 9202, 9203].each do |port|
    flag = { port: port, shutdown: false, items: 0 }
    validator_flags << flag

    worker = Minigun::Cluster::Worker.new(coordinator_uri: nil, worker_id: "validator-#{port}")
    worker.register_stage(:validate) do |item, output|
      flag[:items] += 1
      puts "  [Validator #{port}] Validating item #{item[:id]} (count: #{flag[:items]})"
      output.call(item.merge(validated: true, validated_by: port, validation_time: Time.now.to_f))
    end

    service = create_tracking_service(worker, flag)
    uri = "druby://127.0.0.1:#{port}"
    DRb.start_service(uri, service)
    validator_uris << uri
    puts "  Validator started at #{uri}"
  end

  # Start processor workers (dedicated - SHOULD shutdown)
  processor_uris = []
  [9204, 9205, 9206].each do |port|
    flag = { port: port, shutdown: false, items: 0 }
    processor_flags << flag

    worker = Minigun::Cluster::Worker.new(coordinator_uri: nil, worker_id: "processor-#{port}")
    worker.register_stage(:process) do |item, output|
      flag[:items] += 1
      puts "  [Processor #{port}] Processing item #{item[:id]} (count: #{flag[:items]})"
      result = (1..1000).reduce(item[:value]) { |acc, _| Math.sqrt(acc.abs + 1) }
      output.call(item.merge(processed: true, computed: result.round(4), processed_by: port, processing_time: Time.now.to_f))
    end

    service = create_tracking_service(worker, flag)
    uri = "druby://127.0.0.1:#{port}"
    DRb.start_service(uri, service)
    processor_uris << uri
    puts "  Processor started at #{uri}"
  end

  puts
  puts '--- Running Pipeline ---'
  puts

  pipeline = MultiStageShutdownPipeline.new(
    validator_uris: validator_uris,
    processor_uris: processor_uris
  )
  pipeline.run

  # Give shutdown signals time to propagate
  sleep 0.3

  puts
  puts '=== Shutdown Status ==='
  puts
  puts 'Validators (shutdown_on_done: false - should NOT shutdown):'
  validator_flags.each do |flag|
    status = flag[:shutdown] ? 'SHUTDOWN (unexpected!)' : 'RUNNING (correct)'
    puts "  Port #{flag[:port]}: #{status}, items: #{flag[:items]}"
  end

  puts
  puts 'Processors (shutdown_on_done: true - should shutdown):'
  processor_flags.each do |flag|
    status = flag[:shutdown] ? 'SHUTDOWN (correct)' : 'RUNNING (unexpected!)'
    puts "  Port #{flag[:port]}: #{status}, items: #{flag[:items]}"
  end

  # Verify expectations
  validators_correct = validator_flags.none? { |f| f[:shutdown] }
  processors_correct = processor_flags.all? { |f| f[:shutdown] }

  puts
  puts '=== Verification ==='
  puts "  Validators stayed running: #{validators_correct ? 'PASS' : 'FAIL'}"
  puts "  Processors shutdown: #{processors_correct ? 'PASS' : 'FAIL'}"

  puts
  if validators_correct && processors_correct
    puts 'SUCCESS: Mixed shutdown behavior works correctly!'
  else
    puts 'WARNING: Unexpected shutdown behavior detected'
  end

  puts
  puts '=== Results Summary ==='
  puts "Total items: #{pipeline.results.size}"

  # Show processing path
  puts
  puts 'Processing paths:'
  pipeline.results.sort_by { |r| r[:id] }.first(3).each do |r|
    puts "  Item #{r[:id]}: validator #{r[:validated_by]} -> processor #{r[:processed_by]}"
  end
  puts '  ...'

  # Show work distribution
  puts
  puts 'Validation distribution:'
  by_validator = pipeline.results.group_by { |r| r[:validated_by] }
  by_validator.each { |port, items| puts "  Validator #{port}: #{items.size} items" }

  puts
  puts 'Processing distribution:'
  by_processor = pipeline.results.group_by { |r| r[:processed_by] }
  by_processor.each { |port, items| puts "  Processor #{port}: #{items.size} items" }

  # Run second batch to show validators are still available
  puts
  puts '--- Running Second Batch (validators should still work) ---'
  puts

  # Reset processor flags (they were shutdown, so we won't use them)
  # But validators should still be running

  pipeline2 = MultiStageShutdownPipeline.new(
    validator_uris: validator_uris,
    processor_uris: processor_uris # These will fail since workers shutdown
  )

  begin
    pipeline2.run
    puts "Second batch completed with #{pipeline2.results.size} items"
  rescue Minigun::Cluster::Error => e
    puts 'Expected: Processor workers are gone (they shutdown)'
    puts "  Error: #{e.message}"
    puts
    puts 'This demonstrates that:'
    puts '  - Validators (shutdown_on_done: false) are still available'
    puts '  - Processors (shutdown_on_done: true) have terminated'
  end
rescue StandardError => e
  puts "Error: #{e.message}"
  puts e.backtrace.first(5).join("\n")
ensure
  DRb.stop_service
end

# Helper to create a tracking service
def create_tracking_service(worker, flag)
  service = Object.new
  service.define_singleton_method(:ping) { :pong }
  service.define_singleton_method(:process_item) do |stage_name, item|
    worker.process_item_sync(stage_name, item)
  end
  service.define_singleton_method(:shutdown) do
    flag[:shutdown] = true
    puts "  [Worker #{flag[:port]}] Received SHUTDOWN signal"
  end
  service
end

# Main execution
if __FILE__ == $PROGRAM_NAME
  Minigun.logger.level = Logger::INFO

  mode = ARGV[0] || 'loopback'

  case mode
  when 'loopback'
    run_loopback_test

  when 'help', '--help', '-h'
    puts '=== Multi-Stage Cluster Shutdown Example ==='
    puts
    puts 'Demonstrates pipelines with multiple cluster stages where'
    puts 'different stages have different shutdown_on_done settings.'
    puts
    puts 'Usage:'
    puts '  loopback - Run self-contained test'
    puts
    puts 'Example output shows:'
    puts '  - Validators (shutdown_on_done: false) stay running'
    puts '  - Processors (shutdown_on_done: true) shutdown after completion'

  else
    puts "Unknown mode: #{mode}"
    puts 'Run with --help for usage'
    exit 1
  end
end
