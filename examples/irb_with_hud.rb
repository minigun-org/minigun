#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

# Example: Using Minigun with HUD in IRB/console
#
# This demonstrates the interactive workflow:
#   1. Start a task in background
#   2. Open HUD to monitor it
#   3. Close HUD, task keeps running
#   4. Reopen HUD or stop task
#
# Usage:
#   ruby examples/irb_with_hud.rb
#
# Or in IRB:
#   require './lib/minigun'
#   require './examples/irb_with_hud'
#
#   task = DataProcessingTask.new
#   task.run(background: true)  # Runs in background
#   task.hud                     # Opens HUD monitor
#   # Press 'q' to close HUD (task keeps running)
#   task.running?                # => true
#   task.hud                     # Reopen HUD
#   task.stop                    # Stop execution
class DataProcessingTask
  include Minigun::DSL

  pipeline do
    # Producer - generates continuous stream of data
    producer :data_generator do |output|
      counter = 0
      loop do
        output << { id: counter, data: "item_#{counter}", timestamp: Time.now }
        counter += 1
        sleep rand(0.01..0.05)
      end
    end

    # Processor - enriches data
    processor :enricher, threads: 3 do |item, output|
      enriched = item.merge(
        processed_at: Time.now,
        enriched: true
      )
      sleep rand(0.02..0.08) # Simulate processing time
      output << enriched
    end

    # Processor - validates data
    processor :validator, threads: 2 do |item, output|
      # Simulate validation
      sleep rand(0.01..0.03)
      item[:valid] = true
      output << item
    end

    # Accumulator - batch items
    accumulator :batcher, max_size: 10 do |batch, output|
      output << batch
    end

    # Consumer - process batches
    consumer :batch_processor, threads: 2 do |_batch, _output|
      # Simulate batch processing
      sleep rand(0.05..0.15)
      # Uncomment to see processing messages:
      # puts "Processed batch of #{batch.size} items"
    end
  end
end

# When run directly (not in IRB)
if __FILE__ == $PROGRAM_NAME
  puts '=' * 70
  puts 'Minigun HUD - Interactive Mode Demo'
  puts '=' * 70
  puts
  puts 'This demo shows how to use Minigun with HUD in an interactive workflow:'
  puts
  puts '1. Task will start running in background'
  puts '2. HUD will open automatically to monitor it'
  puts "3. Press 'q' to close HUD (task keeps running)"
  puts "4. You'll see the task is still running"
  puts '5. HUD will reopen for 5 more seconds'
  puts '6. Task will be stopped'
  puts
  puts 'In IRB, you have full control:'
  puts '  task = DataProcessingTask.new'
  puts '  task.run(background: true)  # Start in background'
  puts '  task.hud                     # Open HUD'
  puts '  task.running?                # Check status'
  puts '  task.stop                    # Stop execution'
  puts
  puts 'Press Ctrl+C to quit this demo anytime'
  puts
  puts 'Starting in 3 seconds...'
  sleep 3

  task = DataProcessingTask.new

  # Start in background
  puts "\n[1] Starting task in background..."
  task.run(background: true)

  sleep 1

  # Open HUD
  puts "\n[2] Opening HUD (press 'q' to close it)..."
  sleep 1

  begin
    task.hud
  rescue Interrupt
    puts "\nDemo interrupted"
    task.stop
    exit
  end

  # After closing HUD
  puts "\n[3] HUD closed. Checking if task is still running..."
  sleep 1

  if task.running?
    puts '✓ Task is still running in background!'
    puts
    puts '[4] Reopening HUD for 5 more seconds...'
    sleep 2

    # Reopen HUD in a thread so we can auto-close it
    hud_thread = Thread.new { task.hud }
    sleep 5

    puts "\n[5] Auto-closing HUD and stopping task..."
    hud_thread.kill
    hud_thread.join(1)
  end

  # Stop the task
  task.stop

  puts
  puts '=' * 70
  puts 'Demo complete!'
  puts
  puts 'In IRB, you can start/stop/monitor tasks interactively.'
  puts 'Try it: irb -r ./lib/minigun -r ./examples/irb_with_hud.rb'
  puts '=' * 70
end
