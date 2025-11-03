#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'lib/minigun'

# Enable debug logging
Minigun.logger.level = Logger::DEBUG

class DebugExample
  include Minigun::DSL

  attr_reader :results

  def initialize
    @results = []
    @mutex = Mutex.new
  end

  pipeline do
    producer :generate do |output|
      puts "[Producer] Starting - PID #{Process.pid}"
      sleep 1 # Give workers time to start
      3.times do |i|
        item = { id: i + 1 }
        puts "[Producer] Routing #{item[:id]} to :process"
        output.to(:process) << item
        puts "[Producer] Routed #{item[:id]}"
      end
      puts "[Producer] Done"
    end

    ipc_fork(2) do
      consumer :process, await: true do |item|
        puts "[Consumer:ipc] Processing #{item[:id]} in PID #{Process.pid}"
        @mutex.synchronize do
          @results << item
        end
      end
    end
  end
end

puts "=" * 80
puts "Debug IPC Routing Test"
puts "=" * 80
puts ""

example = DebugExample.new
begin
  example.run
  puts "\n" + "=" * 80
  puts "Results: #{example.results.size} items"
  puts "Expected: 3 items"
  puts "=" * 80
rescue NotImplementedError => e
  puts "\nForking not available: #{e.message}"
end
