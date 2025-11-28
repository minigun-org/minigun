# frozen_string_literal: true

module Minigun
  module Demand
    # Shared demand waiting logic for output queues
    module DemandWaiter
      private

      # Wait for demand if in :auto mode
      # Loops through channels trying to acquire demand with short timeouts
      def wait_for_demand_if_needed
        return if @demand_mode != :auto || @demand_channels.empty?

        loop do
          @demand_channels.each do |channel|
            return if channel.wait_for_demand(1, timeout: 0.01)
          end

          sleep(0.001)
          return if @demand_channels.all?(&:closed?)
        end
      end
    end

    # Wraps InputQueue with demand signaling.
    # Delegates to InputQueue for core functionality, adds demand replenishment.
    #
    # @example
    #   channels = registry.channels_to_consumer(stage)
    #   input = AwareInputQueue.new(raw_queue, stage, sources, demand_channels: channels)
    #
    #   loop do
    #     item = input.pop  # Automatically tracks consumption and replenishes demand
    #     break if item.is_a?(EndOfStage)
    #     process(item)
    #   end
    #
    class AwareInputQueue
      # @param queue [Queue, SizedQueue] The underlying queue
      # @param stage [Stage] The consuming stage
      # @param expected_sources [Array<Stage>] Expected upstream sources
      # @param stage_stats [Stats, nil] Stats tracker
      # @param demand_channels [Array<Channel>] Channels from upstream producers
      def initialize(queue, stage, expected_sources, stage_stats: nil, demand_channels: [])
        @inner = Minigun::InputQueue.new(queue, stage, expected_sources, stage_stats: stage_stats)
        @demand_channels = demand_channels
      end

      # Pop an item from the queue.
      # Delegates to InputQueue, then notifies demand channels.
      # @return [Object, EndOfStage] The next item or end sentinel
      def pop
        item = @inner.pop

        # Notify demand channels about consumption (unless it's end sentinel)
        notify_consumption unless item.is_a?(EndOfStage)

        item
      end

      # Initialize demand on all upstream channels
      # Called when consumer starts.
      # @return [void]
      def initialize_demand
        @demand_channels.each(&:initialize_demand)
      end

      private

      def notify_consumption
        @demand_channels.each(&:on_item_consumed)
      end
    end

    # Wraps OutputQueue with demand gating.
    # Delegates to OutputQueue for core functionality, adds demand waiting.
    #
    # @example
    #   channels = registry.channels_from_producer(stage)
    #   output = AwareOutputQueue.new(stage, downstream_queues, runtime_edges,
    #                                  demand_channels: channels)
    #
    #   # This blocks until demand is available:
    #   output << item
    #
    class AwareOutputQueue
      include DemandWaiter

      # @param stage [Stage] The producing stage
      # @param downstream_queues [Array<Queue>] Downstream stage queues
      # @param runtime_edges [Hash] Runtime edge tracking
      # @param stage_stats [Stats, nil] Stats tracker
      # @param demand_channels [Array<Channel>] Channels to downstream consumers
      # @param demand_mode [Symbol] How demand is handled (:auto, :manual, :disabled)
      # @param demand_timeout [Float, nil] Timeout for demand wait (nil = infinite)
      def initialize(stage, downstream_queues, runtime_edges, stage_stats: nil,
                     demand_channels: [], demand_mode: :auto, demand_timeout: nil)
        @stage = stage
        @inner = Minigun::OutputQueue.new(stage, downstream_queues, runtime_edges, stage_stats: stage_stats)
        @demand_channels = demand_channels
        @demand_mode = demand_mode
        @demand_timeout = demand_timeout
        @to_cache = {}
      end

      # Send item to all downstream stages.
      # In :auto mode, waits for demand before emitting.
      # @param item [Object] Item to send
      # @return [self]
      def <<(item)
        wait_for_demand_if_needed
        @inner << item
        self
      end

      # Route to a specific downstream stage.
      # @param target [Symbol, Stage] Target stage name or object
      # @return [AwareTargetedOutputQueue]
      def to(target)
        return @to_cache[target] if @to_cache.key?(target)

        # Use inner OutputQueue to resolve target and track runtime edge
        inner_targeted = @inner.to(target)

        # Find demand channel to this target (if any)
        # Need to resolve target to Stage for channel lookup
        target_stage = @stage.pipeline.task.stage_registry.find(
          target, from_pipeline: @stage.pipeline
        )
        target_channels = @demand_channels.select { |ch| ch.consumer_stage == target_stage }

        # Create and cache demand-aware wrapper
        @to_cache[target] = AwareTargetedOutputQueue.new(
          inner_targeted,
          demand_channels: target_channels,
          demand_mode: @demand_mode
        )
      end

      # Convert to proc for yield syntax
      def to_proc
        @to_proc ||= proc do |item, to: nil|
          if to
            self.to(to) << item
          else
            self << item
          end
        end
      end

      # --- Manual demand control API ---

      # Wait for demand (for :manual mode)
      # @param count [Integer] Number of tokens
      # @param timeout [Float, nil] Timeout override
      # @return [Boolean] true if demand acquired
      def wait_for_demand(count = 1, timeout: nil)
        return true if @demand_channels.empty?

        timeout ||= @demand_timeout

        @demand_channels.each do |channel|
          return true if channel.wait_for_demand(count, timeout: timeout)
        end

        false
      end

      # Check if demand is available (non-blocking)
      # @return [Boolean]
      def demand_available?
        return true if @demand_channels.empty?

        @demand_channels.any?(&:demand_available?)
      end

      # Current pending demand across all channels
      # @return [Integer]
      def pending_demand
        return Float::INFINITY if @demand_channels.empty?

        @demand_channels.sum(&:pending_demand)
      end
    end

    # Targeted output queue for explicit routing with demand awareness.
    # Wraps an OutputQueue (returned from OutputQueue#to) and adds demand waiting.
    class AwareTargetedOutputQueue
      include DemandWaiter

      # @param inner [OutputQueue] The inner targeted OutputQueue
      # @param demand_channels [Array<Channel>] Channels to target consumer
      # @param demand_mode [Symbol] How demand is handled (:auto, :manual, :disabled)
      def initialize(inner, demand_channels: [], demand_mode: :auto)
        @inner = inner
        @demand_channels = demand_channels
        @demand_mode = demand_mode
      end

      # Send item to the targeted stage
      # @param item [Object]
      # @return [self]
      def <<(item)
        wait_for_demand_if_needed
        @inner << item
        self
      end
    end
  end
end
