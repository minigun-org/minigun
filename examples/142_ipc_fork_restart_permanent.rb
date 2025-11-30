#!/usr/bin/env ruby
# frozen_string_literal: true

# Example: IPC Fork with restart_policy: :permanent
#
# This example demonstrates that workers are ALWAYS restarted,
# even when they exit normally (exit code 0).
#
# Note: :permanent restarts ALL exits, so use with caution.
# In this example, we only crash once per worker to demonstrate
# the behavior without causing infinite restart loops.

require_relative '../lib/minigun'

class PermanentRestartPipeline
  include Minigun::DSL

  pipeline do
    produce_each :items, -> { (1..20).to_a }

    # Workers are ALWAYS restarted, even on normal exit
    # Using lower max_restarts to prevent infinite loops in demo
    in_ipc_forks(2,
                 restart_policy: :permanent,
                 max_restarts: 2,
                 restart_window: 60) do
      processor :work do |item, output|
        # Item 5 and 10: crash with non-zero exit (restarted each time)
        if [5, 10].include?(item)
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

# Enable logging to see restart messages
Minigun.logger.level = Logger::INFO

puts '=== IPC Fork with restart_policy: :permanent ==='
puts 'Workers are ALWAYS restarted on any exit.'
puts 'With max_restarts: 2, workers can restart twice before staying dead.'
puts

PermanentRestartPipeline.new.run

puts
puts 'Pipeline completed with maximum resilience'
