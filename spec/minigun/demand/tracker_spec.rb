# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Minigun::Demand::Tracker do
  describe '#initialize' do
    it 'creates a tracker with default values' do
      tracker = described_class.new

      expect(tracker.min_demand).to eq(500)
      expect(tracker.max_demand).to eq(1000)
      expect(tracker.pending_demand).to eq(0)
      expect(tracker.closed?).to be false
    end

    it 'creates a tracker with custom values' do
      tracker = described_class.new(min_demand: 100, max_demand: 500)

      expect(tracker.min_demand).to eq(100)
      expect(tracker.max_demand).to eq(500)
    end

    it 'raises error if min_demand >= max_demand' do
      expect { described_class.new(min_demand: 500, max_demand: 500) }
        .to raise_error(ArgumentError, /min_demand must be less than max_demand/)

      expect { described_class.new(min_demand: 600, max_demand: 500) }
        .to raise_error(ArgumentError, /min_demand must be less than max_demand/)
    end

    it 'raises error if min_demand is negative' do
      expect { described_class.new(min_demand: -1, max_demand: 100) }
        .to raise_error(ArgumentError, /min_demand must be non-negative/)
    end

    it 'raises error if max_demand is not positive' do
      expect { described_class.new(min_demand: 0, max_demand: -1) }
        .to raise_error(ArgumentError, /max_demand must be positive/)
    end
  end

  describe '#add_demand' do
    it 'increases pending demand' do
      tracker = described_class.new

      tracker.add_demand(100)
      expect(tracker.pending_demand).to eq(100)

      tracker.add_demand(50)
      expect(tracker.pending_demand).to eq(150)
    end

    it 'raises error for negative count' do
      tracker = described_class.new

      expect { tracker.add_demand(-1) }
        .to raise_error(ArgumentError, /count must be non-negative/)
    end

    it 'does nothing if closed' do
      tracker = described_class.new
      tracker.add_demand(100)
      tracker.close

      tracker.add_demand(50)
      expect(tracker.pending_demand).to eq(100)
    end
  end

  describe '#acquire' do
    it 'decrements pending demand when available' do
      tracker = described_class.new
      tracker.add_demand(100)

      result = tracker.acquire(10)

      expect(result).to be true
      expect(tracker.pending_demand).to eq(90)
    end

    it 'blocks until demand is available' do
      tracker = described_class.new

      thread = Thread.new do
        sleep 0.01
        tracker.add_demand(10)
      end

      result = tracker.acquire(5)
      acquired = true

      thread.join

      expect(result).to be true
      expect(acquired).to be true
      expect(tracker.pending_demand).to eq(5)
    end

    it 'returns false on timeout' do
      tracker = described_class.new

      result = tracker.acquire(10, timeout: 0.05)

      expect(result).to be false
      expect(tracker.pending_demand).to eq(0)
    end

    it 'returns false if closed' do
      tracker = described_class.new
      tracker.close

      result = tracker.acquire(10)

      expect(result).to be false
    end

    it 'unblocks waiters when closed' do
      tracker = described_class.new
      result = nil

      thread = Thread.new do
        result = tracker.acquire(10)
      end

      sleep 0.01 # Let thread start waiting
      tracker.close
      thread.join

      expect(result).to be false
    end

    it 'raises error for non-positive count' do
      tracker = described_class.new
      tracker.add_demand(100)

      expect { tracker.acquire(0) }.to raise_error(ArgumentError, /count must be positive/)
      expect { tracker.acquire(-1) }.to raise_error(ArgumentError, /count must be positive/)
    end
  end

  describe '#try_acquire' do
    it 'acquires if demand available' do
      tracker = described_class.new
      tracker.add_demand(100)

      result = tracker.try_acquire(10)

      expect(result).to be true
      expect(tracker.pending_demand).to eq(90)
    end

    it 'returns false if not enough demand' do
      tracker = described_class.new
      tracker.add_demand(5)

      result = tracker.try_acquire(10)

      expect(result).to be false
      expect(tracker.pending_demand).to eq(5)
    end

    it 'returns false if closed' do
      tracker = described_class.new
      tracker.add_demand(100)
      tracker.close

      result = tracker.try_acquire(10)

      expect(result).to be false
    end
  end

  describe '#should_request_more?' do
    it 'returns true when pending < min_demand' do
      tracker = described_class.new(min_demand: 100, max_demand: 500)
      tracker.add_demand(50)

      expect(tracker.should_request_more?).to be true
    end

    it 'returns false when pending >= min_demand' do
      tracker = described_class.new(min_demand: 100, max_demand: 500)
      tracker.add_demand(100)

      expect(tracker.should_request_more?).to be false
    end

    it 'returns false when closed' do
      tracker = described_class.new
      tracker.close

      expect(tracker.should_request_more?).to be false
    end
  end

  describe '#demand_to_request' do
    it 'returns max_demand - pending_demand' do
      tracker = described_class.new(min_demand: 100, max_demand: 500)
      tracker.add_demand(200)

      expect(tracker.demand_to_request).to eq(300)
    end

    it 'returns 0 when pending >= max_demand' do
      tracker = described_class.new(min_demand: 100, max_demand: 500)
      tracker.add_demand(500)

      expect(tracker.demand_to_request).to eq(0)
    end
  end

  describe '#close' do
    it 'marks tracker as closed' do
      tracker = described_class.new

      tracker.close

      expect(tracker.closed?).to be true
    end
  end

  describe '#reset' do
    it 'resets tracker state' do
      tracker = described_class.new
      tracker.add_demand(100)
      tracker.close

      tracker.reset

      expect(tracker.pending_demand).to eq(0)
      expect(tracker.closed?).to be false
    end
  end

  describe 'thread safety' do
    it 'handles concurrent add_demand and acquire' do
      tracker = described_class.new(min_demand: 0, max_demand: 10_000)
      acquired_count = Concurrent::AtomicFixnum.new(0)

      # Add demand from multiple threads
      add_threads = Array.new(5) do
        Thread.new do
          100.times { tracker.add_demand(10) }
        end
      end

      # Acquire from multiple threads
      acquire_threads = Array.new(5) do
        Thread.new do
          100.times do
            acquired_count.increment if tracker.try_acquire(1)
          end
        end
      end

      add_threads.each(&:join)
      acquire_threads.each(&:join)

      # Total added: 5 threads * 100 times * 10 = 5000
      # Acquired should be <= 5000
      expect(acquired_count.value).to be <= 5000
      expect(tracker.pending_demand + acquired_count.value).to eq(5000)
    end
  end
end
