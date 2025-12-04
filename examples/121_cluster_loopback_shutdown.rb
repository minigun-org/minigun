#!/usr/bin/env ruby
# frozen_string_literal: true

# Example: Cluster Loopback with Careful Shutdown Handling
#
# Demonstrates a circular/loopback cluster topology where shutdown_on_done
# must be used carefully to avoid shutting down the originator node.
#
# CRITICAL: In a loopback topology (A -> B -> C -> A), the originating node
# acts as BOTH sender and receiver. If you use shutdown_on_done: true on
# the stage that sends TO the originator, you might inadvertently shutdown
# the originator before it can receive all results!
#
# Pattern:
#   - Intermediate workers: can use shutdown_on_done: true (they just forward)
#   - Final stage (sends back to originator): should NOT shutdown originator
#   - Originator: stays running to collect results
#
# Topology:
#
#   Node A (Originator)
#   - Produces items
#   - Sends to Node B
#   - Receives final results via loopback
#   [shutdown_on_done: false - MUST stay running]
#        |
#        v
#   Node B (Intermediate)
#   - Processes and forwards to Node C
#   [shutdown_on_done: true OK - just forwards]
#        |
#        v
#   Node C (Final processor)
#   - Processes and sends back to Node A
#   [shutdown_on_done: true OK - but Node A stays]
#        |
#        v
#   Back to Node A (receives final results)
#
# Usage:
#   ruby examples/121_cluster_loopback_shutdown.rb loopback

require_relative '../lib/minigun'
require 'drb'

# Simulates a loopback topology where work flows: A -> B -> C -> A
# Node A is special - it's both the producer and final consumer
def run_loopback_test
  puts '=== Loopback Topology with Shutdown Handling ==='
  puts
  puts 'Topology: A -> B -> C -> A (loopback)'
  puts
  puts 'Shutdown behavior:'
  puts '  - Node A (originator): shutdown_on_done: false (MUST stay running)'
  puts '  - Node B (intermediate): shutdown_on_done: true (can shutdown)'
  puts '  - Node C (final): shutdown_on_done: true (can shutdown, A stays)'
  puts

  # Track shutdown state
  node_a_flag = { port: 9301, shutdown: false, items_sent: 0, items_received: 0, role: 'originator' }
  node_b_flag = { port: 9302, shutdown: false, items: 0, role: 'intermediate' }
  node_c_flag = { port: 9303, shutdown: false, items: 0, role: 'final' }

  # Results received back at Node A
  final_results = []
  final_mutex = Mutex.new

  # === Node A: Originator (producer + final receiver) ===
  # This node produces items and receives the final results after they loop back
  node_a_worker = Minigun::Cluster::Worker.new(coordinator_uri: nil, worker_id: 'node-a')

  # Node A receives final results from Node C (stage name must match pipeline's stage name)
  node_a_worker.register_stage(:send_to_a) do |item, output|
    node_a_flag[:items_received] += 1
    puts "  [Node A] Received final result for item #{item[:id]} (loop complete)"
    final_mutex.synchronize { final_results << item }
    output.call({ received: true, id: item[:id] })
  end

  node_a_service = create_tracking_service(node_a_worker, node_a_flag)
  node_a_uri = "druby://127.0.0.1:#{node_a_flag[:port]}"
  DRb.start_service(node_a_uri, node_a_service)
  puts "  Node A (originator) started at #{node_a_uri}"

  # === Node B: Intermediate processor ===
  node_b_worker = Minigun::Cluster::Worker.new(coordinator_uri: nil, worker_id: 'node-b')

  # Stage name must match pipeline's stage name (:send_to_b)
  node_b_worker.register_stage(:send_to_b) do |item, output|
    node_b_flag[:items] += 1
    puts "  [Node B] Processing item #{item[:id]} -> forwarding to C"
    processed = item.merge(
      node_b_processed: true,
      node_b_time: Time.now.to_f
    )
    output.call(processed)
  end

  node_b_service = create_tracking_service(node_b_worker, node_b_flag)
  node_b_uri = "druby://127.0.0.1:#{node_b_flag[:port]}"
  DRb.start_service(node_b_uri, node_b_service)
  puts "  Node B (intermediate) started at #{node_b_uri}"

  # === Node C: Final processor (loops back to A) ===
  node_c_worker = Minigun::Cluster::Worker.new(coordinator_uri: nil, worker_id: 'node-c')

  # Stage name must match pipeline's stage name (:send_to_c)
  node_c_worker.register_stage(:send_to_c) do |item, output|
    node_c_flag[:items] += 1
    puts "  [Node C] Processing item #{item[:id]} -> sending back to A"
    processed = item.merge(
      node_c_processed: true,
      node_c_time: Time.now.to_f,
      loop_complete: true
    )
    output.call(processed)
  end

  node_c_service = create_tracking_service(node_c_worker, node_c_flag)
  node_c_uri = "druby://127.0.0.1:#{node_c_flag[:port]}"
  DRb.start_service(node_c_uri, node_c_service)
  puts "  Node C (final) started at #{node_c_uri}"

  puts
  puts '--- Stage 1: A -> B (originator sends to intermediate) ---'
  puts
  puts 'NOTE: shutdown_on_done affects the TARGET worker (B), not the sender (A)'
  puts '      Using shutdown_on_done: true here to shutdown B after processing'
  puts

  # Stage 1: Node A sends to Node B
  # shutdown_on_done: true because B is intermediate and can shutdown after processing
  stage1_results = []
  items_to_process = 8

  stage1_pipeline = Class.new do
    include Minigun::DSL

    def initialize(node_b_uri, items, results_array)
      @node_b_uri = node_b_uri
      @items = items
      @results = results_array
    end

    pipeline do
      producer :generate do |output|
        @items.times do |i|
          puts "  [Node A] Producing item #{i}"
          output << { id: i, origin: 'A', produced_at: Time.now.to_f }
        end
      end

      # A -> B: Shutdown B after (B is intermediate, can terminate)
      in_cluster(worker_uris: [@node_b_uri], shutdown_on_done: true) do
        processor :send_to_b do |item, output|
          output << item
        end
      end

      consumer :collect_from_b do |item|
        @results << item
      end
    end
  end

  pipeline1 = stage1_pipeline.new(node_b_uri, items_to_process, stage1_results)
  pipeline1.run

  puts
  puts "  Stage 1 complete: #{stage1_results.size} items sent to B"

  puts
  puts '--- Stage 2: B -> C (intermediate forwards to final) ---'
  puts
  puts 'NOTE: shutdown_on_done affects the TARGET worker (C), not the sender'
  puts '      Using shutdown_on_done: true here to shutdown C after processing'
  puts

  # Stage 2: Items from B go to C
  # shutdown_on_done: true to shutdown C after processing
  stage2_results = []

  stage2_pipeline = Class.new do
    include Minigun::DSL

    def initialize(node_c_uri, input_items, results_array)
      @node_c_uri = node_c_uri
      @input_items = input_items
      @results = results_array
    end

    pipeline do
      producer :forward do |output|
        @input_items.each { |item| output << item }
      end

      # -> C: Shutdown C after (C is final processor, can terminate)
      in_cluster(worker_uris: [@node_c_uri], shutdown_on_done: true) do
        processor :send_to_c do |item, output|
          output << item
        end
      end

      consumer :collect_from_c do |item|
        @results << item
      end
    end
  end

  pipeline2 = stage2_pipeline.new(node_c_uri, stage1_results, stage2_results)
  pipeline2.run

  puts
  puts "  Stage 2 complete: #{stage2_results.size} items sent to C"

  puts
  puts '--- Stage 3: C -> A (final sends back to originator, loopback) ---'
  puts
  puts 'CRITICAL: shutdown_on_done affects the TARGET worker (A), the originator!'
  puts '          Using shutdown_on_done: false to KEEP A running!'
  puts '          If we used true, A would shutdown and lose the looped results!'
  puts

  # Stage 3: Items from C go back to A (loopback)
  # CRITICAL: shutdown_on_done: false because A is the originator and MUST stay running
  stage3_results = []

  stage3_pipeline = Class.new do
    include Minigun::DSL

    def initialize(node_a_uri, input_items, results_array)
      @node_a_uri = node_a_uri
      @input_items = input_items
      @results = results_array
    end

    pipeline do
      producer :forward do |output|
        @input_items.each { |item| output << item }
      end

      # -> A (loopback): DO NOT shutdown A (originator must stay running!)
      # This is the CRITICAL point of this example
      in_cluster(worker_uris: [@node_a_uri], shutdown_on_done: false) do
        processor :send_to_a do |item, output|
          output << item
        end
      end

      consumer :collect_loopback do |item|
        @results << item
      end
    end
  end

  pipeline3 = stage3_pipeline.new(node_a_uri, stage2_results, stage3_results)
  pipeline3.run

  puts
  puts "  Stage 3 complete: #{stage3_results.size} items looped back to A"

  # Give shutdown signals time to propagate
  sleep 0.3

  puts
  puts '=== Shutdown Status ==='

  [node_a_flag, node_b_flag, node_c_flag].each do |flag|
    status = flag[:shutdown] ? 'SHUTDOWN' : 'RUNNING'
    role = flag[:role]

    expected = case role
               when 'originator' then 'RUNNING'
               when 'intermediate', 'final' then 'SHUTDOWN'
               end

    correct = status == expected ? '(correct)' : '(UNEXPECTED!)'

    items = flag[:items] || (flag[:items_sent].to_i + flag[:items_received].to_i)
    puts "  Node #{flag[:port]} (#{role}): #{status} #{correct}, items: #{items}"
  end

  # Verify
  a_correct = !node_a_flag[:shutdown]  # Originator should stay running
  b_correct = node_b_flag[:shutdown]   # Intermediate should shutdown
  c_correct = node_c_flag[:shutdown]   # Final should shutdown

  puts
  puts '=== Verification ==='
  puts "  Node A (originator) stayed running: #{a_correct ? 'PASS' : 'FAIL'}"
  puts "  Node B (intermediate) shutdown: #{b_correct ? 'PASS' : 'FAIL'}"
  puts "  Node C (final) shutdown: #{c_correct ? 'PASS' : 'FAIL'}"

  all_pass = a_correct && b_correct && c_correct

  puts
  if all_pass
    puts 'SUCCESS: Loopback shutdown handling works correctly!'
    puts
    puts 'Key insights:'
    puts '  - Originator (A) must use shutdown_on_done: false'
    puts '  - Intermediate nodes (B) can use shutdown_on_done: true'
    puts '  - Final node (C) can use shutdown_on_done: true'
    puts '  - The originator stays running to receive loopback results'
  else
    puts 'WARNING: Unexpected shutdown behavior in loopback topology'
  end

  puts
  puts '=== Loop Journey ==='
  puts "Items produced at A: #{items_to_process}"
  puts "Items received at B: #{node_b_flag[:items]}"
  puts "Items received at C: #{node_c_flag[:items]}"
  puts "Items looped back to A: #{node_a_flag[:items_received]}"
  puts
  puts 'Full loop trace for first item:'
  if stage3_results.any?
    item = stage3_results.first
    puts "  ID: #{item[:id]}"
    puts "  Origin: #{item[:origin]}"
    puts "  Node B processed: #{item[:node_b_processed]}"
    puts "  Node C processed: #{item[:node_c_processed]}"
    puts "  Loop complete: #{item[:loop_complete]}"
  end
rescue StandardError => e
  puts "Error: #{e.message}"
  puts e.backtrace.first(10).join("\n")
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
    puts "  [Node #{flag[:port]}] SHUTDOWN signal received"
  end
  service
end

# Force unbuffered output for test harness compatibility
$stdout.sync = true
$stderr.sync = true

# Configuration via environment variables for testing
NODE_A_PORT = ENV.fetch('NODE_A_PORT', '9301').to_i
NODE_B_PORT = ENV.fetch('NODE_B_PORT', '9302').to_i
NODE_C_PORT = ENV.fetch('NODE_C_PORT', '9303').to_i

# Run a worker node (A, B, or C) as a standalone process
def run_worker_node(node_name, port, stage_name)
  worker = Minigun::Cluster::Worker.new(coordinator_uri: nil, worker_id: "node-#{node_name}-#{Process.pid}")

  case node_name
  when 'a'
    # Node A receives loopback results
    worker.register_stage(stage_name) do |item, output|
      puts "  [Node A] Received loopback result for item #{item[:id]}"
      output.call(item.merge(loopback_received: true))
    end
  when 'b'
    # Node B processes and marks as processed
    worker.register_stage(stage_name) do |item, output|
      puts "  [Node B] Processing item #{item[:id]} -> forwarding"
      output.call(item.merge(node_b_processed: true, node_b_time: Time.now.to_f))
    end
  when 'c'
    # Node C processes and marks for loopback
    worker.register_stage(stage_name) do |item, output|
      puts "  [Node C] Processing item #{item[:id]} -> loopback to A"
      output.call(item.merge(node_c_processed: true, loop_complete: true))
    end
  end

  service = Minigun::Cluster::WorkerService.new(worker)
  DRb.start_service("druby://0.0.0.0:#{port}", service)
  puts "[Node #{node_name.upcase}] Worker started at druby://0.0.0.0:#{port}"

  # Wait for shutdown signal
  shutdown_received = false
  original_shutdown = service.method(:shutdown) if service.respond_to?(:shutdown)

  service.define_singleton_method(:shutdown) do
    shutdown_received = true
    puts "[Node #{node_name.upcase}] SHUTDOWN RECEIVED"
    original_shutdown&.call
  end

  # Keep running until shutdown or timeout
  timeout = ENV.fetch('WORKER_TIMEOUT', '30').to_i
  deadline = Time.now + timeout
  sleep 0.1 until shutdown_received || Time.now > deadline

  puts "[Node #{node_name.upcase}] Exiting (shutdown=#{shutdown_received})"
  DRb.stop_service
end

# Run the client that orchestrates the 3-stage loopback test
def run_client(node_a_port, node_b_port, node_c_port)
  node_a_uri = "druby://127.0.0.1:#{node_a_port}"
  node_b_uri = "druby://127.0.0.1:#{node_b_port}"
  node_c_uri = "druby://127.0.0.1:#{node_c_port}"

  DRb.start_service

  puts '=== Loopback Shutdown Test (Multi-Process) ==='
  puts "Node A: #{node_a_uri}"
  puts "Node B: #{node_b_uri}"
  puts "Node C: #{node_c_uri}"
  puts

  items_to_process = 8

  # Stage 1: A -> B (shutdown_on_done: true for B)
  puts '--- Stage 1: Send to Node B (shutdown_on_done: true) ---'
  stage1_results = []

  stage1_pipeline = Class.new do
    include Minigun::DSL

    def initialize(node_b_uri, items, results_array)
      @node_b_uri = node_b_uri
      @items = items
      @results = results_array
    end

    pipeline do
      producer :generate do |output|
        @items.times { |i| output << { id: i, origin: 'A' } }
      end

      in_cluster(worker_uris: [@node_b_uri], shutdown_on_done: true) do
        processor :send_to_b do |item, output|
          output << item
        end
      end

      consumer :collect do |item|
        @results << item
      end
    end
  end

  stage1_pipeline.new(node_b_uri, items_to_process, stage1_results).run
  puts "Stage 1 complete: #{stage1_results.size} items"

  # Stage 2: B -> C (shutdown_on_done: true for C)
  puts '--- Stage 2: Send to Node C (shutdown_on_done: true) ---'
  stage2_results = []

  stage2_pipeline = Class.new do
    include Minigun::DSL

    def initialize(node_c_uri, input_items, results_array)
      @node_c_uri = node_c_uri
      @input_items = input_items
      @results = results_array
    end

    pipeline do
      producer :forward do |output|
        @input_items.each { |item| output << item }
      end

      in_cluster(worker_uris: [@node_c_uri], shutdown_on_done: true) do
        processor :send_to_c do |item, output|
          output << item
        end
      end

      consumer :collect do |item|
        @results << item
      end
    end
  end

  stage2_pipeline.new(node_c_uri, stage1_results, stage2_results).run
  puts "Stage 2 complete: #{stage2_results.size} items"

  # Stage 3: C -> A (shutdown_on_done: false for A - CRITICAL!)
  puts '--- Stage 3: Loopback to Node A (shutdown_on_done: false) ---'
  stage3_results = []

  stage3_pipeline = Class.new do
    include Minigun::DSL

    def initialize(node_a_uri, input_items, results_array)
      @node_a_uri = node_a_uri
      @input_items = input_items
      @results = results_array
    end

    pipeline do
      producer :forward do |output|
        @input_items.each { |item| output << item }
      end

      # CRITICAL: shutdown_on_done: false to keep A running
      in_cluster(worker_uris: [@node_a_uri], shutdown_on_done: false) do
        processor :send_to_a do |item, output|
          output << item
        end
      end

      consumer :collect do |item|
        @results << item
      end
    end
  end

  stage3_pipeline.new(node_a_uri, stage2_results, stage3_results).run
  puts "Stage 3 complete: #{stage3_results.size} items looped back"

  # Verify results
  puts
  puts '=== Results ==='
  puts "Items produced: #{items_to_process}"
  puts "Items after stage 1 (via B): #{stage1_results.size}"
  puts "Items after stage 2 (via C): #{stage2_results.size}"
  puts "Items after stage 3 (loopback to A): #{stage3_results.size}"

  # Check that Node A is still reachable (wasn't shutdown)
  puts
  puts '=== Verification ==='

  # Helper to wait for node to shutdown (or confirm still running)
  wait_for_shutdown = lambda do |uri, timeout: 10|
    deadline = Time.now + timeout
    loop do
      node = DRbObject.new_with_uri(uri)
      node.ping
      # Still running after timeout
      break false if Time.now > deadline

      sleep 0.05
    rescue DRb::DRbConnError
      break true # Shutdown confirmed
    end
  end

  # Check Node A stays running (quick check, should be reachable)
  begin
    node_a = DRbObject.new_with_uri(node_a_uri)
    node_a.ping
    puts 'Node A (originator) stayed running: PASS'
    a_pass = true
  rescue DRb::DRbConnError
    puts 'Node A (originator) stayed running: FAIL (not reachable)'
    a_pass = false
  end

  # Wait for Node B to shutdown
  if wait_for_shutdown.call(node_b_uri, timeout: 10)
    puts 'Node B (intermediate) shutdown: PASS'
    b_pass = true
  else
    puts 'Node B (intermediate) shutdown: FAIL (still running)'
    b_pass = false
  end

  # Wait for Node C to shutdown
  if wait_for_shutdown.call(node_c_uri, timeout: 10)
    puts 'Node C (final) shutdown: PASS'
    c_pass = true
  else
    puts 'Node C (final) shutdown: FAIL (still running)'
    c_pass = false
  end

  all_pass = a_pass && b_pass && c_pass && stage3_results.size == items_to_process

  puts
  if all_pass
    puts 'SUCCESS'
  else
    puts 'FAIL'
    exit 1
  end
ensure
  DRb.stop_service
end

# Main execution
if __FILE__ == $PROGRAM_NAME
  Minigun.logger.level = Logger::INFO

  mode = ARGV[0] || 'loopback'

  case mode
  when 'loopback'
    run_loopback_test

  when 'node_a'
    port = ARGV[1]&.to_i || NODE_A_PORT
    run_worker_node('a', port, :send_to_a)

  when 'node_b'
    port = ARGV[1]&.to_i || NODE_B_PORT
    run_worker_node('b', port, :send_to_b)

  when 'node_c'
    port = ARGV[1]&.to_i || NODE_C_PORT
    run_worker_node('c', port, :send_to_c)

  when 'client'
    node_a_port = ARGV[1]&.to_i || NODE_A_PORT
    node_b_port = ARGV[2]&.to_i || NODE_B_PORT
    node_c_port = ARGV[3]&.to_i || NODE_C_PORT
    run_client(node_a_port, node_b_port, node_c_port)

  when 'help', '--help', '-h'
    puts '=== Cluster Loopback Shutdown Example ==='
    puts
    puts 'Demonstrates careful shutdown handling in a circular topology.'
    puts
    puts 'In a loopback (A -> B -> C -> A), the originator node must NOT'
    puts 'be shutdown, or it cannot receive the final looped-back results.'
    puts
    puts 'Pattern:'
    puts '  - Originator: shutdown_on_done: false (stays running)'
    puts '  - Intermediate nodes: shutdown_on_done: true (can shutdown)'
    puts '  - Final node: shutdown_on_done: true (originator still runs)'
    puts
    puts 'Usage:'
    puts '  loopback              - Run self-contained single-process test'
    puts '  node_a [PORT]         - Run Node A worker (originator)'
    puts '  node_b [PORT]         - Run Node B worker (intermediate)'
    puts '  node_c [PORT]         - Run Node C worker (final)'
    puts '  client A_PORT B_PORT C_PORT - Run client orchestrator'

  else
    puts "Unknown mode: #{mode}"
    puts 'Run with --help for usage'
    exit 1
  end
end
