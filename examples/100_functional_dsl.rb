#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'
require 'stringio'

# Functional DSL Example
# Demonstrates the simplified Minigun.task syntax for quick pipeline creation
#
# This syntax is ideal for:
# - One-off scripts and batch jobs
# - IRB/console experimentation
# - Simple pipelines that don't need class-level configuration

if __FILE__ == $PROGRAM_NAME
  puts "=== Functional DSL Example ===\n\n"

  # Example 1: Simple pipeline with Minigun.task
  puts '--- Example 1: Basic Minigun.task ---'
  results = []
  mutex = Mutex.new

  task = Minigun.task('simple_example') do
    produce :numbers do |output|
      10.times { |i| output << i }
    end

    consume :collector do |item|
      mutex.synchronize { results << item * 2 }
    end
  end

  task.run
  puts "Results: #{results.sort.inspect}"
  puts ''

  # Example 2: Using debatch and rebatch
  puts '--- Example 2: Debatch and Rebatch ---'
  batch_sizes = []
  mutex2 = Mutex.new

  task2 = Minigun.task('batch_example') do
    # Produce batches of 100 items
    produce :batches do |output|
      3.times do |batch_num|
        batch = (1..100).map { |i| "item_#{batch_num}_#{i}" }
        output << batch
      end
    end

    # Rebatch from 100 to 25
    rebatch(25)

    consume :process_batches do |batch|
      mutex2.synchronize { batch_sizes << batch.size }
    end
  end

  task2.run
  puts "Batch sizes after rebatch(25): #{batch_sizes.inspect}"
  puts "Total batches: #{batch_sizes.size} (expected: 12)"
  puts ''

  # Example 3: Threaded processing
  puts '--- Example 3: Threaded Processing ---'
  processed = Concurrent::AtomicFixnum.new(0)

  task3 = Minigun.task('threaded_example') do
    produce :source do |output|
      100.times { |i| output << i }
    end

    in_threads(4) do
      consume :worker do |_item|
        processed.increment
        sleep 0.001 # Simulate work
      end
    end
  end

  task3.run
  puts "Processed #{processed.value} items with 4 threads"
  puts ''

  # Example 4: Full newsletter sender pattern
  puts '--- Example 4: Newsletter Sender Pattern ---'

  # Simulated user data (5 batches of 1000 users each)
  user_batches = 5.times.map do |batch_num|
    (1..1000).map { |i| { id: batch_num * 1000 + i, email: "user#{batch_num * 1000 + i}@example.com" } }
  end

  emails_sent = Concurrent::AtomicFixnum.new(0)

  task4 = Minigun.task('newsletter_sender') do
    # Producer: Emit batches of users
    produce :user_batches do |output|
      user_batches.each { |batch| output << batch }
    end

    # Rebatch from 1000 to 100 for better parallelism
    rebatch(100)

    # Unpack batches into individual users
    debatch

    # Send emails in parallel threads
    in_threads(10) do
      consume :send_email do |_user|
        emails_sent.increment
        # Simulate sending email:
        # NewsletterMailer.with(user: user).deliver_now
      end
    end
  end

  task4.run
  puts "Sent #{emails_sent.value} emails (expected: 5000)"
  puts ''

  # Example 5: Background execution with start
  puts '--- Example 5: Background Execution ---'
  bg_results = []
  bg_mutex = Mutex.new

  task5 = Minigun.task('background_task') do
    produce :source do |output|
      5.times { |i| output << i }
    end

    consume :sink do |item|
      sleep 0.01
      bg_mutex.synchronize { bg_results << item }
    end
  end

  # Suppress output from start
  original_stdout = $stdout
  $stdout = StringIO.new
  task5.start
  $stdout = original_stdout

  puts "Task running in background: #{task5.running?}"
  task5.wait
  puts "Background task completed. Results: #{bg_results.sort.inspect}"
  puts ''

  puts '=== Functional DSL Example Complete ==='
end
