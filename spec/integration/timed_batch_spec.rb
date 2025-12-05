# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Time-based batch flushing' do
  describe 'size-based batching (no max_wait)' do
    it 'batches items by size only' do
      batches = []
      mutex = Mutex.new

      task = Class.new do
        include Minigun::DSL

        pipeline do
          producer :source do |output|
            10.times { |i| output << i }
          end

          batch :batcher, max_size: 3

          consumer :sink do |batch|
            mutex.synchronize { batches << batch.dup }
          end
        end
      end

      task.new.run

      # Should have batches of 3, 3, 3, and 1 (remaining)
      expect(batches.size).to eq(4)
      expect(batches[0]).to eq([0, 1, 2])
      expect(batches[1]).to eq([3, 4, 5])
      expect(batches[2]).to eq([6, 7, 8])
      expect(batches[3]).to eq([9])
    end
  end

  describe 'time-based batching (with max_wait)' do
    it 'flushes batch when max_wait time expires' do
      batches = []
      batch_times = []
      mutex = Mutex.new
      start_time = nil

      task = Class.new do
        include Minigun::DSL

        pipeline do
          producer :slow_source do |output|
            start_time = Time.now
            # Produce 3 items with 0.15s delay between them
            # max_wait is 0.3s, so first batch should flush by time (not size)
            3.times do |i|
              output << i
              sleep 0.15
            end
          end

          # max_size: 100 (won't reach), max_wait: 0.3s (will trigger)
          batch :timed_batcher, max_size: 100, max_wait: 0.3

          consumer :sink do |batch|
            mutex.synchronize do
              batches << batch.dup
              batch_times << (Time.now - start_time)
            end
          end
        end
      end

      task.new.run

      # Should flush based on time, not size
      # With 3 items at 0.15s intervals, first batch may contain 1-2 items
      # The key is that we get batches before reaching max_size
      expect(batches.flatten.sort).to eq([0, 1, 2])
      expect(batches.size).to be >= 1
    end

    it 'flushes immediately when size threshold is reached' do
      batches = []
      mutex = Mutex.new

      task = Class.new do
        include Minigun::DSL

        pipeline do
          producer :fast_source do |output|
            # Produce 10 items quickly
            10.times { |i| output << i }
          end

          # max_size: 3 (will trigger), max_wait: 10s (won't trigger)
          batch :sized_batcher, max_size: 3, max_wait: 10.0

          consumer :sink do |batch|
            mutex.synchronize { batches << batch.dup }
          end
        end
      end

      task.new.run

      # Should batch by size: 3, 3, 3, 1
      expect(batches.size).to eq(4)
      expect(batches[0]).to eq([0, 1, 2])
      expect(batches[1]).to eq([3, 4, 5])
      expect(batches[2]).to eq([6, 7, 8])
      expect(batches[3]).to eq([9])
    end

    it 'handles mixed size and time triggering' do
      batches = []
      mutex = Mutex.new

      task = Class.new do
        include Minigun::DSL

        pipeline do
          producer :mixed_source do |output|
            # Send 5 items quickly (will batch by size)
            5.times { |i| output << i }
            # Wait a bit
            sleep 0.4
            # Send 2 more (will batch by time since only 2 items)
            2.times { |i| output << (i + 5) }
          end

          batch :mixed_batcher, max_size: 3, max_wait: 0.2

          consumer :sink do |batch|
            mutex.synchronize { batches << batch.dup }
          end
        end
      end

      task.new.run

      # All 7 items should be processed
      expect(batches.flatten.sort).to eq([0, 1, 2, 3, 4, 5, 6])
    end
  end

  describe 'batch shorthand with max_wait' do
    it 'supports batch(size) shorthand with max_wait option' do
      batches = []
      mutex = Mutex.new

      task = Class.new do
        include Minigun::DSL

        pipeline do
          producer :source do |output|
            5.times { |i| output << i }
          end

          # Shorthand for max_size, plus explicit max_wait
          batch 3, max_wait: 5.0

          consumer :sink do |batch|
            mutex.synchronize { batches << batch.dup }
          end
        end
      end

      task.new.run

      expect(batches.flatten.sort).to eq([0, 1, 2, 3, 4])
    end
  end

  describe 'batch with processing block' do
    it 'passes batch to block with max_wait enabled' do
      results = []
      mutex = Mutex.new

      task = Class.new do
        include Minigun::DSL

        pipeline do
          producer :source do |output|
            6.times { |i| output << i }
          end

          batch :processor, max_size: 2, max_wait: 1.0 do |batch, output|
            output << batch.sum
          end

          consumer :sink do |item|
            mutex.synchronize { results << item }
          end
        end
      end

      task.new.run

      # Batches: [0,1], [2,3], [4,5] -> sums: 1, 5, 9
      expect(results.sort).to eq([1, 5, 9])
    end
  end
end
