#!/usr/bin/env ruby
# frozen_string_literal: true

# Example: IPC Fork with restart_policy: :never (default)
#
# This example demonstrates the default behavior where workers
# are NOT restarted when they crash.

require_relative '../lib/minigun'

# Pipeline demonstrating :never restart policy (workers not restarted on crash)
class NeverRestartPipeline
  include Minigun::DSL

  pipeline do
    produce_each :items, -> { (1..20).to_a }

    # Default restart_policy is :never - workers stay dead if they crash
    in_ipc_forks(2, restart_policy: :never) do
      processor :work do |item, output|
        # Item 10 will cause a crash - worker won't be restarted
        if item == 10
          warn "[Worker #{Process.pid}] Crashing on item 10!"
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

puts '=== IPC Fork with restart_policy: :never ==='
puts 'One worker will crash on item 10 and NOT be restarted.'
puts 'Some items may be lost due to the crash.'
puts

NeverRestartPipeline.new.run

puts
puts 'Pipeline completed (with potential item loss)'
