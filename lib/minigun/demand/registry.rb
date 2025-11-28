# frozen_string_literal: true

require_relative 'channel'

module Minigun
  module Demand
    # Manages all demand channels for a pipeline.
    # Each producer-consumer edge in the DAG gets its own channel.
    #
    # The registry provides lookup methods for both sides:
    # - Producers look up channels to their downstream consumers
    # - Consumers look up channels from their upstream producers
    #
    # @example
    #   registry = Registry.new
    #
    #   # During pipeline setup:
    #   registry.register(producer_stage, consumer_stage, min_demand: 100, max_demand: 500)
    #
    #   # Producer lookup:
    #   channels = registry.channels_from_producer(producer_stage)
    #   channels.each { |ch| ch.wait_for_demand }
    #
    #   # Consumer lookup:
    #   channels = registry.channels_to_consumer(consumer_stage)
    #   channels.each { |ch| ch.initialize_demand }
    #
    class Registry
      def initialize
        @channels = {}  # { [producer, consumer] => Channel }
        @by_producer = Hash.new { |h, k| h[k] = [] }
        @by_consumer = Hash.new { |h, k| h[k] = [] }
        @mutex = Mutex.new
      end

      # Register a demand channel between producer and consumer
      # @param producer_stage [Stage] Upstream stage
      # @param consumer_stage [Stage] Downstream stage
      # @param min_demand [Integer] Threshold to trigger replenishment
      # @param max_demand [Integer] Maximum items to request at once
      # @return [Channel] The created or existing channel
      def register(producer_stage, consumer_stage, min_demand: 500, max_demand: 1000)
        key = [producer_stage, consumer_stage]

        @mutex.synchronize do
          return @channels[key] if @channels.key?(key)

          channel = Channel.new(
            producer_stage,
            consumer_stage,
            min_demand: min_demand,
            max_demand: max_demand
          )

          @channels[key] = channel
          @by_producer[producer_stage] << channel
          @by_consumer[consumer_stage] << channel

          channel
        end
      end

      # Get channel for a specific producer-consumer pair
      # @param producer_stage [Stage]
      # @param consumer_stage [Stage]
      # @return [Channel, nil]
      def channel_for(producer_stage, consumer_stage)
        @mutex.synchronize { @channels[[producer_stage, consumer_stage]] }
      end

      # Get all channels from a producer (to its downstream consumers)
      # @param producer_stage [Stage]
      # @return [Array<Channel>]
      def channels_from_producer(producer_stage)
        @mutex.synchronize { @by_producer[producer_stage].dup }
      end

      # Get all channels to a consumer (from its upstream producers)
      # @param consumer_stage [Stage]
      # @return [Array<Channel>]
      def channels_to_consumer(consumer_stage)
        @mutex.synchronize { @by_consumer[consumer_stage].dup }
      end

      # Check if any channels are registered
      # @return [Boolean]
      def empty?
        @mutex.synchronize { @channels.empty? }
      end

      # Number of registered channels
      # @return [Integer]
      def size
        @mutex.synchronize { @channels.size }
      end

      # All registered channels
      # @return [Array<Channel>]
      def all_channels
        @mutex.synchronize { @channels.values.dup }
      end

      # Close all channels (called on pipeline completion)
      # @return [void]
      def close_all
        @mutex.synchronize do
          @channels.each_value(&:close)
        end
      end

      # Clear all channels (for testing)
      # @return [void]
      def clear
        @mutex.synchronize do
          @channels.clear
          @by_producer.clear
          @by_consumer.clear
        end
      end

      # Debug representation
      def to_s
        @mutex.synchronize do
          channel_strs = @channels.map { |(p, c), ch| "#{p.name}->#{c.name}:#{ch.pending_demand}" }
          "#<Demand::Registry channels=[#{channel_strs.join(', ')}]>"
        end
      end

      alias inspect to_s
    end
  end
end
