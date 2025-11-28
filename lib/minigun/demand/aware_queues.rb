# frozen_string_literal: true

module Minigun
  module Demand
    # Wraps InputQueue with demand signaling.
    # After consuming items, automatically requests more when below min_demand.
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
        @queue = queue
        @stage = stage
        @sources_expected = Set.new(expected_sources)
        @sources_done = Set.new
        @stage_stats = stage_stats
        @demand_channels = demand_channels
      end

      # Pop an item from the queue.
      # Handles EndOfSource signals and triggers demand replenishment.
      # @return [Object, EndOfStage] The next item or end sentinel
      def pop
        loop do
          item = @queue.pop

          # Handle EndOfSource signals
          if item.is_a?(EndOfSource)
            @sources_expected << item.stage  # Discover dynamic source
            @sources_done << item.stage

            # All sources done? Return sentinel
            return EndOfStage.new(@stage) if @sources_done == @sources_expected

            # More sources pending, keep looping
            next
          end

          # Track consumption
          @stage_stats&.increment_consumed

          # Notify demand channels about consumption
          notify_consumption

          # Regular item
          return item
        end
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
    # Producers must wait for demand before emitting items.
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
      # Demand modes:
      # - :auto - wait for demand before each emit (default)
      # - :manual - producer controls demand via explicit calls
      # - :disabled - no demand control, acts like regular OutputQueue
      MODES = %i[auto manual disabled].freeze

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
        @downstream_queues = downstream_queues
        @runtime_edges = runtime_edges
        @stage_stats = stage_stats
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

        @downstream_queues.each { |queue| queue << item }
        @stage_stats&.increment_produced
        self
      end

      # Route to a specific downstream stage.
      # @param target [Symbol, Stage] Target stage name or object
      # @return [AwareTargetedOutputQueue]
      def to(target)
        return @to_cache[target] if @to_cache.key?(target)

        # Resolve target to Stage object
        target_stage = task.stage_registry.find(target, from_pipeline: pipeline)
        raise ArgumentError, "Unknown target stage: #{target}" unless target_stage

        # Look up queue
        target_queue = task.find_queue(target_stage)
        raise ArgumentError, "Unknown target stage queue: #{target}" unless target_queue

        # Track runtime edge
        @runtime_edges[@stage] ||= Set.new
        @runtime_edges[@stage].add(target_stage)

        # Find demand channel to this target (if any)
        target_channels = @demand_channels.select { |ch| ch.consumer_stage == target_stage }

        # Create and cache
        @to_cache[target] = AwareTargetedOutputQueue.new(
          @stage,
          target_queue,
          target_stage,
          @runtime_edges,
          stage_stats: @stage_stats,
          demand_channels: target_channels,
          demand_mode: @demand_mode,
          demand_timeout: @demand_timeout
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

      private

      def wait_for_demand_if_needed
        return if @demand_mode != :auto || @demand_channels.empty?

        # Wait on first channel that has demand
        # This provides a simple strategy - could be more sophisticated
        loop do
          @demand_channels.each do |channel|
            return if channel.wait_for_demand(1, timeout: 0.01)
          end

          # Small sleep to avoid busy loop, then retry
          sleep(0.001)

          # Check if all channels are closed
          return if @demand_channels.all?(&:closed?)
        end
      end

      def pipeline
        @stage.pipeline
      end

      def task
        pipeline&.task
      end
    end

    # Targeted output queue for explicit routing with demand awareness.
    class AwareTargetedOutputQueue
      def initialize(stage, target_queue, target_stage, runtime_edges, stage_stats: nil,
                     demand_channels: [], demand_mode: :auto, demand_timeout: nil)
        @stage = stage
        @target_queue = target_queue
        @target_stage = target_stage
        @runtime_edges = runtime_edges
        @stage_stats = stage_stats
        @demand_channels = demand_channels
        @demand_mode = demand_mode
        @demand_timeout = demand_timeout
      end

      # Send item to the targeted stage
      # @param item [Object]
      # @return [self]
      def <<(item)
        wait_for_demand_if_needed

        @target_queue << item
        @stage_stats&.increment_produced
        self
      end

      private

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
  end
end
