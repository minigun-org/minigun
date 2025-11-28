# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Minigun::Demand::Registry do
  let(:producer1) { instance_double('Minigun::Stage', name: :producer1) }
  let(:producer2) { instance_double('Minigun::Stage', name: :producer2) }
  let(:consumer1) { instance_double('Minigun::Stage', name: :consumer1) }
  let(:consumer2) { instance_double('Minigun::Stage', name: :consumer2) }

  describe '#register' do
    it 'creates a channel between producer and consumer' do
      registry = described_class.new

      channel = registry.register(producer1, consumer1)

      expect(channel).to be_a(Minigun::Demand::Channel)
      expect(channel.producer_stage).to eq(producer1)
      expect(channel.consumer_stage).to eq(consumer1)
    end

    it 'returns existing channel if already registered' do
      registry = described_class.new

      channel1 = registry.register(producer1, consumer1)
      channel2 = registry.register(producer1, consumer1)

      expect(channel1).to equal(channel2)
    end

    it 'accepts custom demand settings' do
      registry = described_class.new

      channel = registry.register(producer1, consumer1, min_demand: 100, max_demand: 500)

      expect(channel.min_demand).to eq(100)
      expect(channel.max_demand).to eq(500)
    end
  end

  describe '#channel_for' do
    it 'returns the channel for a producer-consumer pair' do
      registry = described_class.new
      registered_channel = registry.register(producer1, consumer1)

      found_channel = registry.channel_for(producer1, consumer1)

      expect(found_channel).to eq(registered_channel)
    end

    it 'returns nil if no channel exists' do
      registry = described_class.new

      channel = registry.channel_for(producer1, consumer1)

      expect(channel).to be_nil
    end
  end

  describe '#channels_from_producer' do
    it 'returns all channels from a producer' do
      registry = described_class.new
      channel1 = registry.register(producer1, consumer1)
      channel2 = registry.register(producer1, consumer2)
      registry.register(producer2, consumer1) # Different producer

      channels = registry.channels_from_producer(producer1)

      expect(channels).to contain_exactly(channel1, channel2)
    end

    it 'returns empty array if producer has no channels' do
      registry = described_class.new

      channels = registry.channels_from_producer(producer1)

      expect(channels).to eq([])
    end
  end

  describe '#channels_to_consumer' do
    it 'returns all channels to a consumer' do
      registry = described_class.new
      channel1 = registry.register(producer1, consumer1)
      channel2 = registry.register(producer2, consumer1)
      registry.register(producer1, consumer2) # Different consumer

      channels = registry.channels_to_consumer(consumer1)

      expect(channels).to contain_exactly(channel1, channel2)
    end

    it 'returns empty array if consumer has no channels' do
      registry = described_class.new

      channels = registry.channels_to_consumer(consumer1)

      expect(channels).to eq([])
    end
  end

  describe '#empty?' do
    it 'returns true when no channels registered' do
      registry = described_class.new

      expect(registry.empty?).to be true
    end

    it 'returns false when channels exist' do
      registry = described_class.new
      registry.register(producer1, consumer1)

      expect(registry.empty?).to be false
    end
  end

  describe '#size' do
    it 'returns the number of channels' do
      registry = described_class.new

      expect(registry.size).to eq(0)

      registry.register(producer1, consumer1)
      expect(registry.size).to eq(1)

      registry.register(producer1, consumer2)
      expect(registry.size).to eq(2)
    end
  end

  describe '#all_channels' do
    it 'returns all registered channels' do
      registry = described_class.new
      channel1 = registry.register(producer1, consumer1)
      channel2 = registry.register(producer2, consumer2)

      channels = registry.all_channels

      expect(channels).to contain_exactly(channel1, channel2)
    end
  end

  describe '#close_all' do
    it 'closes all channels' do
      registry = described_class.new
      channel1 = registry.register(producer1, consumer1)
      channel2 = registry.register(producer2, consumer2)

      registry.close_all

      expect(channel1.closed?).to be true
      expect(channel2.closed?).to be true
    end
  end

  describe '#clear' do
    it 'removes all channels' do
      registry = described_class.new
      registry.register(producer1, consumer1)
      registry.register(producer2, consumer2)

      registry.clear

      expect(registry.empty?).to be true
      expect(registry.channels_from_producer(producer1)).to eq([])
    end
  end

  describe 'thread safety' do
    it 'handles concurrent registrations' do
      registry = described_class.new
      producers = 10.times.map { |i| instance_double('Minigun::Stage', name: :"producer#{i}") }
      consumers = 10.times.map { |i| instance_double('Minigun::Stage', name: :"consumer#{i}") }

      threads = producers.zip(consumers).map do |producer, consumer|
        Thread.new { registry.register(producer, consumer) }
      end

      threads.each(&:join)

      expect(registry.size).to eq(10)
    end
  end
end
