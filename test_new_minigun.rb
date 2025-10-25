#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'lib_new/minigun'

# Simple test of the new Minigun implementation
class SimpleTest
  include Minigun::DSL

  max_threads 3
  max_processes 2

  pipeline do
    producer :generate do
      puts "Producing 20 items..."
      20.times do |i|
        emit(i + 1)
      end
    end

    processor :double do |num|
      emit(num * 2)
    end

    consumer :print do |num|
      puts "[Consumer:#{Process.pid}] Processing: #{num}"
      sleep 0.1 # Simulate work
    end
  end

  before_run do
    puts "=== Starting Pipeline ==="
  end

  after_run do
    puts "=== Pipeline Complete ==="
  end

  before_fork do
    puts "[Parent] About to fork consumer..."
  end

  after_fork do
    puts "[Child:#{Process.pid}] Consumer forked!"
  end
end

# Run it
task = SimpleTest.new
task.run

