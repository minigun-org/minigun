#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

# Example: Await Modes for Dynamic Routing
#
# Demonstrates different await: modes for handling DAG-disconnected stages
# that receive items via dynamic routing (output.to(:stage_name)).
#
# When a stage has no DAG upstream connections but receives items via
# output.to(), you can control how long it waits before shutting down:
#
# 1. await: (default) - 5 second timeout with warning
# 2. await: true      - infinite wait, no warning
# 3. await: 30        - custom timeout (30s), no warning
# 4. await: false     - immediate shutdown, no warning
# 5. Normal DAG       - no await needed
#
# Architecture:
# - Router uses output.to() for dynamic routing
# - Target stages have no DAG upstream (disconnected)
# - Different await modes demonstrate different behaviors

class AwaitModesExample
  include Minigun::DSL

  attr_reader :default_results, :infinite_results, :custom_results, :normal_results

  def initialize
    @default_results = []
    @infinite_results = []
    @custom_results = []
    @normal_results = []
    @mutex = Mutex.new
  end

  pipeline do
    # Router stage - uses dynamic routing via output.to()
    producer :router do |output|
      puts "\n[Router] Starting dynamic routing (PID #{Process.pid})"

      # Send items to different stages
      3.times do |i|
        item = { id: i + 1, timestamp: Time.now.to_f }

        puts "[Router] Routing item #{item[:id]} to :default_await"
        output.to(:default_await) << item.merge(target: 'default')

        puts "[Router] Routing item #{item[:id]} to :infinite_await"
        output.to(:infinite_await) << item.merge(target: 'infinite')

        puts "[Router] Routing item #{item[:id]} to :custom_await"
        output.to(:custom_await) << item.merge(target: 'custom')

        puts "[Router] Routing item #{item[:id]} to :normal_dag"
        output.to(:normal_dag) << item.merge(target: 'normal')

        sleep 0.1
      end

      puts '[Router] Done routing'
    end

    # Case 1: Default await (no await specified)
    # - Stage has no DAG upstream
    # - Will LOG WARNING about using default 5s timeout
    # - Waits 5 seconds for first item
    # - Items arrive quickly, so it stays alive
    consumer :default_await do |item|
      puts "  [DefaultAwait] Received #{item[:id]} (target: #{item[:target]}) in PID #{Process.pid}"
      sleep 0.01
      @mutex.synchronize do
        @default_results << item.merge(worker_pid: Process.pid)
      end
    end

    # Case 2: Infinite await (await: true)
    # - Stage has no DAG upstream
    # - NO WARNING (explicit await: true)
    # - Waits forever for items (or until END signal)
    consumer :infinite_await, await: true do |item|
      puts "  [InfiniteAwait] Received #{item[:id]} (target: #{item[:target]}) in PID #{Process.pid}"
      sleep 0.01
      @mutex.synchronize do
        @infinite_results << item.merge(worker_pid: Process.pid)
      end
    end

    # Case 3: Custom timeout (await: 30)
    # - Stage has no DAG upstream
    # - NO WARNING (explicit await: 30)
    # - Waits 30 seconds for first item
    # - Items arrive quickly, so it stays alive
    consumer :custom_await, await: 30 do |item|
      puts "  [CustomAwait] Received #{item[:id]} (target: #{item[:target]}) in PID #{Process.pid}"
      sleep 0.01
      @mutex.synchronize do
        @custom_results << item.merge(worker_pid: Process.pid)
      end
    end

    # Case 4: Normal DAG-connected stage
    # - Stage has DAG upstream (router -> normal_dag)
    # - NO WARNING (has upstream)
    # - No await needed
    consumer :normal_dag do |item|
      puts "  [NormalDAG] Received #{item[:id]} (target: #{item[:target]}) in PID #{Process.pid}"
      sleep 0.01
      @mutex.synchronize do
        @normal_results << item.merge(worker_pid: Process.pid)
      end
    end
  end
end

# Example with await: false (immediate shutdown)
class ImmediateShutdownExample
  include Minigun::DSL

  attr_reader :connected_results, :disconnected_results

  def initialize
    @connected_results = []
    @disconnected_results = []
  end

  pipeline do
    producer :source do |output|
      puts "\n[Source] Generating item"
      output.to(:connected_stage) << { id: 1 }
      # NOTE: not routing to :disconnected_stage
    end

    # This stage receives items and works normally
    consumer :connected_stage, await: true do |item|
      puts "  [Connected] Received item #{item[:id]}"
      @connected_results << item
    end

    # This stage has no DAG upstream and await: false
    # It will shutdown immediately since nothing routes to it
    # This demonstrates intentional fast-fail for disconnected stages
    consumer :disconnected_stage, await: false do |item|
      puts '  [Disconnected] Should never see this!'
      @disconnected_results << item
    end
  end
end

# Run the examples
puts '=' * 80
puts 'Example 1: Different Await Modes'
puts '=' * 80
puts "\nNote: The :default_await stage will show a WARNING about using 5s default timeout."
puts "This is expected behavior when a stage has no DAG upstream and no await: setting.\n"

example1 = AwaitModesExample.new
example1.run

puts "\nResults:"
puts "  Default await (5s with warning): #{example1.default_results.size} items"
puts "  Infinite await (no warning):     #{example1.infinite_results.size} items"
puts "  Custom await 30s (no warning):   #{example1.custom_results.size} items"
puts "  Normal DAG (no warning):         #{example1.normal_results.size} items"

puts "\n#{'=' * 80}"
puts 'Example 2: Immediate Shutdown (await: false)'
puts '=' * 80
puts "\nThis stage will shutdown immediately because it has no DAG upstream"
puts "and await: false is set. This is useful for detecting pipeline bugs.\n"

example2 = ImmediateShutdownExample.new
example2.run

puts "\nResults:"
puts "  Connected stage: #{example2.connected_results.size} items (should be 1)"
puts "  Disconnected stage: #{example2.disconnected_results.size} items (should be 0)"

puts "\n#{'=' * 80}"
puts 'Summary'
puts '=' * 80
puts <<~SUMMARY

  Await Modes:

  1. No await specified (default):
     - DAG-disconnected stages get 5s timeout
     - Shows WARNING to help detect bugs
     - Use for: letting Minigun auto-detect issues

  2. await: true (infinite):
     - Waits forever for items
     - No warning
     - Use for: long-running services, webhook receivers

  3. await: 30 (custom timeout):
     - Waits N seconds for first item
     - No warning
     - Use for: conditional routing with custom timeouts

  4. await: false (immediate shutdown):
     - Shuts down immediately if no DAG upstream
     - No warning
     - Use for: fast-fail detection of pipeline bugs

  5. Normal DAG-connected:
     - No await needed
     - No warning
     - Use for: standard pipeline flow

SUMMARY
