# frozen_string_literal: true

module Minigun
  module Cluster
    # Barrier for coordinating multiple cluster stages
    # Ensures all cluster stages have workers connected before any starts distributing
    #
    # Usage:
    #   barrier = Barrier.new
    #
    #   # Each cluster stage registers when created
    #   barrier.register(:preprocess)
    #   barrier.register(:heavy_compute)
    #   barrier.register(:postprocess)
    #
    #   # Each stage signals ready after workers connect, then waits
    #   # (in separate threads)
    #   barrier.ready(:preprocess)  # blocks until all ready
    #   barrier.ready(:heavy_compute)  # blocks until all ready
    #   barrier.ready(:postprocess)  # releases all
    #
    class Barrier
      def initialize
        @mutex = Mutex.new
        @cv = ConditionVariable.new
        @registered = Set.new
        @ready_stages = Set.new
        @released = false
      end

      # Register a cluster stage that will participate in the barrier
      # Must be called before ready() for that stage
      def register(stage_name)
        @mutex.synchronize do
          @registered.add(stage_name.to_sym)
          Minigun.logger.debug "[Cluster::Barrier] Registered stage :#{stage_name} (#{@registered.size} total)"
        end
      end

      # Signal that a stage is ready (workers connected) and wait for all others
      # Blocks until all registered stages are ready
      # Returns true when released, false if already released (idempotent)
      def ready(stage_name)
        @mutex.synchronize do
          return true if @released

          stage_sym = stage_name.to_sym
          @ready_stages.add(stage_sym)

          Minigun.logger.debug "[Cluster::Barrier] Stage :#{stage_name} ready (#{@ready_stages.size}/#{@registered.size})"

          if @ready_stages.size >= @registered.size
            # All stages ready - release the barrier
            @released = true
            Minigun.logger.debug "[Cluster::Barrier] All #{@registered.size} cluster stages ready, releasing barrier"
            @cv.broadcast
            return true
          end

          # Wait for other stages
          @cv.wait(@mutex) until @released
          true
        end
      end

      # Check if all stages are ready (non-blocking)
      def all_ready?
        @mutex.synchronize { @released }
      end

      # Get count of registered stages
      def registered_count
        @mutex.synchronize { @registered.size }
      end

      # Get count of ready stages
      def ready_count
        @mutex.synchronize { @ready_stages.size }
      end

      # Reset the barrier (for testing)
      def reset
        @mutex.synchronize do
          @registered.clear
          @ready_stages.clear
          @released = false
        end
      end
    end
  end
end
