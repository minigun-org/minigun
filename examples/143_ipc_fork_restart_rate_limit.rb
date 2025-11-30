#!/usr/bin/env ruby
# frozen_string_literal: true

# Example: IPC Fork with restart rate limiting
#
# This example demonstrates how max_restarts and restart_window
# prevent restart storms by limiting how many times a worker can restart.

require_relative '../lib/minigun'

class RateLimitedRestartPipeline
  include Minigun::DSL

  pipeline do
    produce_each :items, -> { (1..50).to_a }

    # Workers can restart at most 2 times within 10 seconds
    # After that, they stay dead
    in_ipc_forks(2,
                 restart_policy: :transient,
                 max_restarts: 2,
                 restart_window: 10) do
      processor :flaky_work do |item, output|
        # Every 5th item causes a crash
        if (item % 5).zero?
          warn "[Worker #{Process.pid}] Crashing on item #{item}!"
          exit!(1)
        end

        warn "[Worker #{Process.pid}] Processing item #{item}"
        output << (item * 2)
      end
    end

    consumer :collect do |result|
      warn "[Consumer] Got result: #{result}"
    end
  end
end

# Enable logging to see restart and rate limit messages
Minigun.logger.level = Logger::INFO

puts '=== IPC Fork with restart rate limiting ==='
puts 'Workers crash every 5 items, but can only restart 2 times per 10 seconds.'
puts 'After hitting the limit, workers stay dead.'
puts
puts 'max_restarts: 2'
puts 'restart_window: 10 seconds'
puts

RateLimitedRestartPipeline.new.run

puts
puts 'Pipeline completed (some items lost due to rate limiting)'
