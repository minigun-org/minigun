# frozen_string_literal: true

require_relative 'tracker'

module Minigun
  module Demand
    # Communication channel between a producer and consumer for demand signals.
    # Wraps a Tracker and provides the interface for both sides of the connection.
    #
    # Each producer-consumer pair has its own Channel, allowing independent
    # demand tracking even when a producer feeds multiple consumers.
    #
    # @example
    #   channel = Channel.new(producer_stage, consumer_stage, min_demand: 100, max_demand: 500)
    #
    #   # Consumer side: request items
    #   channel.request(500)  # Initial demand
    #
    #   # Producer side: wait for demand before emitting
    #   if channel.wait_for_demand
    #     output << item
    #   end
    #
    #   # Consumer side: after processing, check for replenishment
    #   channel.maybe_replenish
    #
    class Channel
      attr_reader :producer_stage, :consumer_stage, :tracker

      # @param producer_stage [Stage] The upstream producer stage
      # @param consumer_stage [Stage] The downstream consumer stage
      # @param min_demand [Integer] Threshold to trigger demand replenishment
      # @param max_demand [Integer] Maximum items to request at once
      def initialize(producer_stage, consumer_stage, min_demand: 500, max_demand: 1000)
        @producer_stage = producer_stage
        @consumer_stage = consumer_stage
        @tracker = Tracker.new(min_demand: min_demand, max_demand: max_demand)
        @items_consumed = 0
        @mutex = Mutex.new
      end

      # --- Consumer Side API ---

      # Request items from the producer
      # @param count [Integer] Number of items to request
      # @return [void]
      def request(count)
        @tracker.add_demand(count)
      end

      # Send initial demand (typically max_demand)
      # Called when consumer starts up.
      # @return [void]
      def initialize_demand
        request(@tracker.max_demand)
      end

      # Track item consumption and maybe request more
      # Called by consumer after processing an item.
      # @return [void]
      def on_item_consumed
        @mutex.synchronize { @items_consumed += 1 }
        maybe_replenish
      end

      # Check and send demand replenishment if needed
      # @return [Boolean] true if replenishment was sent
      def maybe_replenish
        return false unless @tracker.should_request_more?

        amount = @tracker.demand_to_request
        return false if amount <= 0

        request(amount)
        true
      end

      # --- Producer Side API ---

      # Wait for demand before emitting an item
      # @param count [Integer] Number of tokens to acquire (default: 1)
      # @param timeout [Float, nil] Maximum seconds to wait (nil = infinite)
      # @return [Boolean] true if demand available, false if timeout/closed
      def wait_for_demand(count = 1, timeout: nil)
        @tracker.acquire(count, timeout: timeout)
      end

      # Try to acquire demand without blocking
      # @param count [Integer] Number of tokens to acquire
      # @return [Boolean] true if acquired, false otherwise
      def try_wait_for_demand(count = 1)
        @tracker.try_acquire(count)
      end

      # Check if any demand is available (non-blocking)
      # @return [Boolean]
      def demand_available?
        @tracker.pending_demand.positive?
      end

      # Current pending demand
      # @return [Integer]
      def pending_demand
        @tracker.pending_demand
      end

      # --- Lifecycle ---

      # Close the channel (signals completion)
      # @return [void]
      def close
        @tracker.close
      end

      # Check if channel is closed
      # @return [Boolean]
      def closed?
        @tracker.closed?
      end

      # --- Configuration Access ---

      # @return [Integer]
      def min_demand
        @tracker.min_demand
      end

      # @return [Integer]
      def max_demand
        @tracker.max_demand
      end

      # --- Stats ---

      # Number of items consumed through this channel
      # @return [Integer]
      def items_consumed
        @mutex.synchronize { @items_consumed }
      end

      # Debug representation
      def to_s
        "#<Demand::Channel #{@producer_stage&.name}->#{@consumer_stage&.name} " \
          "pending=#{pending_demand} consumed=#{items_consumed}>"
      end

      alias_method :inspect, :to_s
    end
  end
end
