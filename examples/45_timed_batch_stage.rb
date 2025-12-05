#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

# Demonstrates time-based batch flushing using the built-in max_wait option.
#
# The batch stage will flush when EITHER condition is met:
# - max_size items have been collected (size-based)
# - max_wait seconds have elapsed since last flush (time-based)
#
# This is useful for scenarios where:
# - You want to batch items for efficiency (e.g., bulk database inserts)
# - But also need timely processing when items arrive slowly
class TimedBatchExample
  include Minigun::DSL

  pipeline do
    producer :generate do |output|
      20.times do |i|
        output << i
        sleep 0.05 # Simulate slow production (50ms between items)
      end
    end

    # Batch with both size and time limits:
    # - max_size: 5 - flush when 5 items collected
    # - max_wait: 0.3 - flush after 0.3 seconds even if < 5 items
    batch :batcher, max_size: 5, max_wait: 0.3

    consumer :process do |batch, _output|
      puts "Processing batch of #{batch.size} items: #{batch.inspect}"
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  puts "\n=== Timed Batch Stage Example ==="
  puts 'Batches items with size limit (5) and timeout (0.3s)'
  puts "Watch how batches are flushed both when full and on timeout\n\n"

  TimedBatchExample.new.run

  puts "\n=== Example Complete ==="
end
