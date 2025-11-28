# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Minigun::Demand::Channel do
  let(:producer_stage) do
    instance_double(Minigun::Stage, name: :producer)
  end

  let(:consumer_stage) do
    instance_double(Minigun::Stage, name: :consumer)
  end

  describe '#initialize' do
    it 'creates a channel with default values' do
      channel = described_class.new(producer_stage, consumer_stage)

      expect(channel.producer_stage).to eq(producer_stage)
      expect(channel.consumer_stage).to eq(consumer_stage)
      expect(channel.min_demand).to eq(500)
      expect(channel.max_demand).to eq(1000)
      expect(channel.pending_demand).to eq(0)
    end

    it 'creates a channel with custom values' do
      channel = described_class.new(producer_stage, consumer_stage,
                                    min_demand: 100, max_demand: 500)

      expect(channel.min_demand).to eq(100)
      expect(channel.max_demand).to eq(500)
    end
  end

  describe 'consumer side API' do
    describe '#request' do
      it 'adds demand to the tracker' do
        channel = described_class.new(producer_stage, consumer_stage)

        channel.request(100)

        expect(channel.pending_demand).to eq(100)
      end
    end

    describe '#initialize_demand' do
      it 'requests max_demand items' do
        channel = described_class.new(producer_stage, consumer_stage,
                                      min_demand: 100, max_demand: 500)

        channel.initialize_demand

        expect(channel.pending_demand).to eq(500)
      end
    end

    describe '#on_item_consumed' do
      it 'tracks consumption' do
        channel = described_class.new(producer_stage, consumer_stage,
                                      min_demand: 3, max_demand: 10)
        channel.initialize_demand

        5.times { channel.on_item_consumed }

        expect(channel.items_consumed).to eq(5)
      end

      it 'triggers replenishment when below min_demand' do
        channel = described_class.new(producer_stage, consumer_stage,
                                      min_demand: 5, max_demand: 10)
        channel.request(6) # Start with 6

        # Simulate consuming items
        # After each acquire, pending drops
        channel.tracker.acquire(1) # pending = 5
        channel.tracker.acquire(1) # pending = 4 (below min_demand)
        channel.on_item_consumed # Should trigger replenishment

        # Replenishment should have happened
        expect(channel.pending_demand).to be >= 5
      end
    end

    describe '#maybe_replenish' do
      it 'requests more when below min_demand' do
        channel = described_class.new(producer_stage, consumer_stage,
                                      min_demand: 50, max_demand: 100)

        # Add some demand below threshold
        channel.request(30)

        result = channel.maybe_replenish

        expect(result).to be true
        expect(channel.pending_demand).to eq(100) # 30 + 70 = 100
      end

      it 'does not request when above min_demand' do
        channel = described_class.new(producer_stage, consumer_stage,
                                      min_demand: 50, max_demand: 100)
        channel.request(60)

        result = channel.maybe_replenish

        expect(result).to be false
        expect(channel.pending_demand).to eq(60)
      end
    end
  end

  describe 'producer side API' do
    describe '#wait_for_demand' do
      it 'blocks until demand is available' do
        channel = described_class.new(producer_stage, consumer_stage)

        thread = Thread.new do
          sleep 0.01
          channel.request(10)
        end

        result = channel.wait_for_demand(5)
        acquired = result

        thread.join

        expect(acquired).to be true
        expect(channel.pending_demand).to eq(5)
      end

      it 'returns false on timeout' do
        channel = described_class.new(producer_stage, consumer_stage)

        result = channel.wait_for_demand(10, timeout: 0.05)

        expect(result).to be false
      end
    end

    describe '#try_wait_for_demand' do
      it 'returns true if demand available' do
        channel = described_class.new(producer_stage, consumer_stage)
        channel.request(100)

        result = channel.try_wait_for_demand(10)

        expect(result).to be true
        expect(channel.pending_demand).to eq(90)
      end

      it 'returns false if not enough demand' do
        channel = described_class.new(producer_stage, consumer_stage)
        channel.request(5)

        result = channel.try_wait_for_demand(10)

        expect(result).to be false
        expect(channel.pending_demand).to eq(5)
      end
    end

    describe '#demand_available?' do
      it 'returns true when demand > 0' do
        channel = described_class.new(producer_stage, consumer_stage)
        channel.request(10)

        expect(channel.demand_available?).to be true
      end

      it 'returns false when demand = 0' do
        channel = described_class.new(producer_stage, consumer_stage)

        expect(channel.demand_available?).to be false
      end
    end
  end

  describe 'lifecycle' do
    describe '#close' do
      it 'closes the channel' do
        channel = described_class.new(producer_stage, consumer_stage)

        channel.close

        expect(channel.closed?).to be true
      end

      it 'unblocks waiting producers' do
        channel = described_class.new(producer_stage, consumer_stage)
        result = nil

        thread = Thread.new do
          result = channel.wait_for_demand(10)
        end

        sleep 0.01 # Let thread start waiting
        channel.close
        thread.join

        expect(result).to be false
      end
    end
  end

  describe 'watermark behavior' do
    it 'maintains steady-state flow with watermarks' do
      channel = described_class.new(producer_stage, consumer_stage,
                                    min_demand: 50, max_demand: 100)

      # Initial demand
      channel.initialize_demand
      expect(channel.pending_demand).to eq(100)

      # Simulate producer sending items and consumer consuming
      # Each acquire decrements pending, each on_item_consumed may replenish
      50.times do
        channel.wait_for_demand(1)
      end

      # After consuming 50, pending should be at 50 (min_demand)
      expect(channel.pending_demand).to eq(50)

      # One more consume should trigger replenishment
      channel.wait_for_demand(1)
      channel.on_item_consumed

      # Should have replenished to near max
      expect(channel.pending_demand).to be >= 50
    end
  end
end
