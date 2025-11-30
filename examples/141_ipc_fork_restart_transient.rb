#!/usr/bin/env ruby
# frozen_string_literal: true

# Example: IPC Fork with restart_policy: :transient
#
# This example demonstrates automatic worker restart on abnormal exits.
# Workers that crash (signal or non-zero exit) are restarted.
# Workers that exit normally (exit code 0) are not restarted.

require_relative '../lib/minigun'

class TransientRestartPipeline
  include Minigun::DSL

  pipeline do
    produce_each :items, -> { (1..20).to_a }

    # Workers restart on crashes, but not on normal exit
    in_ipc_forks(2,
                 restart_policy: :transient,
                 max_restarts: 3,
                 restart_window: 60) do
      processor :work do |item, output|
        # Item 5 will cause a crash - worker WILL be restarted
        if item == 5
          warn "[Worker #{Process.pid}] Crashing on item 5!"
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

puts '=== IPC Fork with restart_policy: :transient ==='
puts 'Worker will crash on item 5 but will be automatically restarted.'
puts 'Subsequent items will continue processing after restart.'
puts

TransientRestartPipeline.new.run

puts
puts 'Pipeline completed with automatic worker recovery'
