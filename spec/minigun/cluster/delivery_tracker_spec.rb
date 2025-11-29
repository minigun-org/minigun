# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Minigun::Cluster::DeliveryTracker do
  let(:tracker) { described_class.new(max_retries: 3) }

  describe '#initialize' do
    it 'sets max_retries' do
      expect(tracker.max_retries).to eq(3)
    end

    it 'defaults max_retries to 3' do
      default_tracker = described_class.new
      expect(default_tracker.max_retries).to eq(3)
    end

    it 'starts with no in-flight items' do
      expect(tracker.in_flight_count).to eq(0)
    end

    it 'starts with no completed items' do
      expect(tracker.completed_count).to eq(0)
    end

    it 'starts complete (no items)' do
      expect(tracker.all_complete?).to be true
    end
  end

  describe '#generate_id' do
    it 'generates unique monotonic IDs' do
      ids = 10.times.map { tracker.generate_id }
      expect(ids).to eq([1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
    end

    it 'is thread-safe' do
      ids = []
      mutex = Mutex.new

      threads = 10.times.map do
        Thread.new do
          5.times do
            id = tracker.generate_id
            mutex.synchronize { ids << id }
          end
        end
      end
      threads.each(&:join)

      # Should have 50 unique IDs
      expect(ids.size).to eq(50)
      expect(ids.uniq.size).to eq(50)
    end
  end

  describe '#track' do
    it 'returns a unique item ID' do
      id1 = tracker.track({ value: 1 }, worker_uri: 'druby://localhost:9000')
      id2 = tracker.track({ value: 2 }, worker_uri: 'druby://localhost:9001')

      expect(id1).to be_a(Integer)
      expect(id2).to be_a(Integer)
      expect(id1).not_to eq(id2)
    end

    it 'increments in_flight_count' do
      expect { tracker.track({ value: 1 }, worker_uri: 'druby://localhost:9000') }
        .to change { tracker.in_flight_count }.from(0).to(1)
    end

    it 'marks tracker as not complete' do
      tracker.track({ value: 1 }, worker_uri: 'druby://localhost:9000')
      expect(tracker.all_complete?).to be false
    end
  end

  describe '#complete' do
    let!(:item_id) { tracker.track({ value: 1 }, worker_uri: 'druby://localhost:9000') }

    it 'returns true for first completion' do
      expect(tracker.complete(item_id)).to be true
    end

    it 'returns false for duplicate completion' do
      tracker.complete(item_id)
      expect(tracker.complete(item_id)).to be false
    end

    it 'decrements in_flight_count' do
      expect { tracker.complete(item_id) }
        .to change { tracker.in_flight_count }.from(1).to(0)
    end

    it 'increments completed_count' do
      expect { tracker.complete(item_id) }
        .to change { tracker.completed_count }.from(0).to(1)
    end

    it 'makes tracker complete when last item completed' do
      tracker.complete(item_id)
      expect(tracker.all_complete?).to be true
    end

    it 'returns false for unknown item_id' do
      expect(tracker.complete(9999)).to be false
    end
  end

  describe '#fail' do
    let!(:item_id) { tracker.track({ value: 1 }, worker_uri: 'druby://localhost:9000') }

    context 'with retries remaining' do
      it 'returns :retry' do
        expect(tracker.fail(item_id, error: 'connection lost')).to eq(:retry)
      end

      it 'queues item for retry' do
        tracker.fail(item_id, error: 'connection lost')
        retry_data = tracker.next_retry
        expect(retry_data).not_to be_nil
        expect(retry_data[:item_id]).to eq(item_id)
        expect(retry_data[:item]).to eq({ value: 1 })
        expect(retry_data[:retries]).to eq(1)
      end

      it 'keeps item in-flight (for retry tracking)' do
        tracker.fail(item_id, error: 'connection lost')
        expect(tracker.in_flight_count).to eq(1)
      end
    end

    context 'when max retries exceeded' do
      before do
        # Exhaust retries (max_retries: 3 means 3 retries after initial attempt)
        3.times do
          tracker.fail(item_id, error: 'connection lost')
          retry_data = tracker.next_retry
          tracker.update_for_retry(item_id, item: retry_data[:item], worker_uri: 'druby://localhost:9000', retries: retry_data[:retries])
        end
      end

      it 'returns :exhausted' do
        expect(tracker.fail(item_id, error: 'final failure')).to eq(:exhausted)
      end

      it 'removes item from in-flight' do
        tracker.fail(item_id, error: 'final failure')
        expect(tracker.in_flight_count).to eq(0)
      end

      it 'makes tracker complete' do
        tracker.fail(item_id, error: 'final failure')
        expect(tracker.all_complete?).to be true
      end
    end

    context 'for already completed item' do
      before { tracker.complete(item_id) }

      it 'returns :already_completed' do
        expect(tracker.fail(item_id, error: 'late failure')).to eq(:already_completed)
      end
    end

    context 'for unknown item_id' do
      it 'returns :not_found' do
        expect(tracker.fail(9999, error: 'unknown')).to eq(:not_found)
      end
    end
  end

  describe '#update_for_retry' do
    let!(:item_id) { tracker.track({ value: 1 }, worker_uri: 'druby://localhost:9000') }

    it 'updates the tracked item' do
      tracker.update_for_retry(item_id, item: { value: 1 }, worker_uri: 'druby://localhost:9001', retries: 1)
      # Can't directly inspect, but verify it doesn't crash
      expect(tracker.in_flight_count).to eq(1)
    end
  end

  describe '#next_retry' do
    it 'returns nil when no retries pending' do
      expect(tracker.next_retry).to be_nil
    end

    it 'returns queued retry data' do
      item_id = tracker.track({ value: 42 }, worker_uri: 'druby://localhost:9000')
      tracker.fail(item_id, error: 'test')

      retry_data = tracker.next_retry
      expect(retry_data[:item_id]).to eq(item_id)
      expect(retry_data[:item]).to eq({ value: 42 })
      expect(retry_data[:retries]).to eq(1)
    end

    it 'is non-blocking' do
      start = Time.now
      tracker.next_retry
      elapsed = Time.now - start
      expect(elapsed).to be < 0.1
    end
  end

  describe '#all_complete?' do
    it 'returns true when empty' do
      expect(tracker.all_complete?).to be true
    end

    it 'returns false when items in-flight' do
      tracker.track({ value: 1 }, worker_uri: 'druby://localhost:9000')
      expect(tracker.all_complete?).to be false
    end

    it 'returns false when retries pending' do
      item_id = tracker.track({ value: 1 }, worker_uri: 'druby://localhost:9000')
      tracker.fail(item_id, error: 'test')
      expect(tracker.all_complete?).to be false
    end

    it 'returns true when all items completed' do
      item_id = tracker.track({ value: 1 }, worker_uri: 'druby://localhost:9000')
      tracker.complete(item_id)
      expect(tracker.all_complete?).to be true
    end
  end

  describe '#stats' do
    it 'returns correct stats' do
      # Track 3 items
      id1 = tracker.track({ value: 1 }, worker_uri: 'druby://localhost:9000')
      id2 = tracker.track({ value: 2 }, worker_uri: 'druby://localhost:9000')
      tracker.track({ value: 3 }, worker_uri: 'druby://localhost:9000')

      # Complete 1, fail 1 (queues retry)
      tracker.complete(id1)
      tracker.fail(id2, error: 'test')

      stats = tracker.stats
      expect(stats[:in_flight]).to eq(2) # id2 still in-flight (pending retry), id3 in-flight
      expect(stats[:completed]).to eq(1)
      expect(stats[:retries_pending]).to eq(1)
    end
  end

  describe 'thread safety' do
    it 'handles concurrent track/complete operations' do
      ids = []
      mutex = Mutex.new

      # Track 100 items from 10 threads
      track_threads = 10.times.map do
        Thread.new do
          10.times do |i|
            id = tracker.track({ value: i }, worker_uri: 'druby://localhost:9000')
            mutex.synchronize { ids << id }
          end
        end
      end
      track_threads.each(&:join)

      expect(ids.size).to eq(100)
      expect(tracker.in_flight_count).to eq(100)

      # Complete all from 10 threads
      complete_threads = ids.each_slice(10).map do |batch|
        Thread.new do
          batch.each { |id| tracker.complete(id) }
        end
      end
      complete_threads.each(&:join)

      expect(tracker.in_flight_count).to eq(0)
      expect(tracker.completed_count).to eq(100)
      expect(tracker.all_complete?).to be true
    end
  end
end
