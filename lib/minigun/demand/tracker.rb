# frozen_string_literal: true

module Minigun
  module Demand
    # Tracks demand tokens between a producer and consumer.
    # Implements the core counting logic for pull-based backpressure.
    #
    # The tracker maintains a count of "pending demand" - items that a consumer
    # has requested but not yet received. Producers must acquire demand tokens
    # before emitting items.
    #
    # Watermark thresholds (min_demand/max_demand) control automatic replenishment:
    # - When pending demand drops below min_demand, consumer requests more
    # - Consumer requests enough to bring pending demand back up to max_demand
    # - This creates batches of (max_demand - min_demand) items
    #
    # @example
    #   tracker = Tracker.new(min_demand: 500, max_demand: 1000)
    #   tracker.add_demand(1000)  # Consumer requests 1000 items
    #
    #   # Producer side:
    #   tracker.acquire(1)  # Blocks until demand available, decrements by 1
    #   # emit item...
    #
    #   # Consumer side (after processing items):
    #   if tracker.should_request_more?
    #     tracker.add_demand(tracker.demand_to_request)
    #   end
    #
    class Tracker
      attr_reader :min_demand, :max_demand

      # @param min_demand [Integer] Threshold to trigger demand replenishment (default: 500)
      # @param max_demand [Integer] Maximum items to request at once (default: 1000)
      def initialize(min_demand: 500, max_demand: 1000)
        raise ArgumentError, 'min_demand must be non-negative' if min_demand < 0
        raise ArgumentError, 'max_demand must be positive' if max_demand <= 0
        raise ArgumentError, 'min_demand must be less than max_demand' if min_demand >= max_demand

        @min_demand = min_demand
        @max_demand = max_demand
        @pending_demand = 0
        @mutex = Mutex.new
        @demand_available = ConditionVariable.new
        @closed = false
      end

      # Current pending demand (thread-safe read)
      # @return [Integer] Number of items that can be emitted
      def pending_demand
        @mutex.synchronize { @pending_demand }
      end

      # Add demand tokens (called by consumer to request items)
      # @param count [Integer] Number of items to request
      # @return [void]
      def add_demand(count)
        raise ArgumentError, 'count must be non-negative' if count < 0

        @mutex.synchronize do
          return if @closed

          @pending_demand += count
          @demand_available.broadcast
        end
      end

      # Acquire demand tokens before emitting (called by producer)
      # Blocks until demand is available or timeout expires.
      #
      # @param count [Integer] Number of tokens to acquire (default: 1)
      # @param timeout [Float, nil] Maximum seconds to wait (nil = infinite)
      # @return [Boolean] true if tokens acquired, false if timeout/closed
      def acquire(count = 1, timeout: nil)
        raise ArgumentError, 'count must be positive' if count <= 0

        @mutex.synchronize do
          return false if @closed

          deadline = timeout ? Time.now + timeout : nil

          while @pending_demand < count
            return false if @closed

            if deadline
              remaining = deadline - Time.now
              return false if remaining <= 0

              @demand_available.wait(@mutex, remaining)
            else
              @demand_available.wait(@mutex)
            end

            return false if @closed
          end

          @pending_demand -= count
          true
        end
      end

      # Try to acquire demand without blocking
      # @param count [Integer] Number of tokens to acquire
      # @return [Boolean] true if tokens acquired, false otherwise
      def try_acquire(count = 1)
        raise ArgumentError, 'count must be positive' if count <= 0

        @mutex.synchronize do
          return false if @closed || @pending_demand < count

          @pending_demand -= count
          true
        end
      end

      # Check if demand replenishment is needed
      # Called by consumer after processing items.
      # @return [Boolean] true if pending demand is below min_demand
      def should_request_more?
        @mutex.synchronize { !@closed && @pending_demand < @min_demand }
      end

      # Calculate how much demand to request to reach max_demand
      # @return [Integer] Number of items to request
      def demand_to_request
        @mutex.synchronize { [@max_demand - @pending_demand, 0].max }
      end

      # Close the tracker (on completion/error)
      # Unblocks any waiting producers.
      # @return [void]
      def close
        @mutex.synchronize do
          @closed = true
          @demand_available.broadcast
        end
      end

      # Check if tracker is closed
      # @return [Boolean]
      def closed?
        @mutex.synchronize { @closed }
      end

      # Reset tracker state (for testing)
      # @return [void]
      def reset
        @mutex.synchronize do
          @pending_demand = 0
          @closed = false
        end
      end

      # Debug representation
      def to_s
        @mutex.synchronize do
          "#<Demand::Tracker pending=#{@pending_demand} min=#{@min_demand} max=#{@max_demand} closed=#{@closed}>"
        end
      end

      alias_method :inspect, :to_s
    end
  end
end
