# frozen_string_literal: true

module Minigun
  # Shared behavior for IPC output queues (cross-process communication via pipes)
  # Provides shutdown handling and serialization with error recovery.
  module IpcOutputBehavior
    # IPC workers don't have direct access to pipeline state
    # They receive :shutdown messages via the pipe instead
    def shutdown?
      @shutdown_requested
    end

    # Request shutdown by sending message to parent process
    def shutdown!(force: false)
      @shutdown_requested = true
      ipc_send(type: :shutdown_request, force: force)
    end

    private

    # Send a message through the IPC pipe with error handling
    def ipc_send(**message)
      Marshal.dump(message, @pipe_writer)
      @pipe_writer.flush
    rescue IOError, Errno::EPIPE
      # Pipe closed, parent already shutting down
    end

    # Send a result with serialization error handling
    def ipc_send_with_recovery(message)
      Marshal.dump(message, @pipe_writer)
      @pipe_writer.flush
      @stage_stats&.increment_produced
    rescue TypeError, ArgumentError => e
      Minigun.logger.warn "[Minigun] Cannot serialize result for IPC: #{e.message}"
      ipc_send(
        type: :serialization_error,
        error: "Cannot serialize result: #{e.message}",
        item_type: (message[:result] || message[:item])&.class.to_s
      )
    end
  end

  # Wrapper around stage input queue that handles EndOfSource signals
  class InputQueue
    def initialize(queue, stage, expected_sources, stage_stats: nil)
      @queue = queue
      @stage = stage
      @sources_expected = Set.new(expected_sources)
      @sources_done = Set.new
      @stage_stats = stage_stats
    end

    # Pop items from queue, consuming EndOfSource signals
    # Returns EndOfStage sentinel when all upstreams are done
    def pop
      loop do
        item = @queue.pop

        # Handle EndOfSource signals
        if item.is_a?(EndOfSource)
          @sources_expected << item.stage # Discover dynamic source Stage object
          @sources_done << item.stage

          # All sources done? Return sentinel
          return EndOfStage.new(@stage) if @sources_done == @sources_expected

          # More sources pending, keep looping to get next item
          next
        end

        # Track consumption of regular items
        @stage_stats&.increment_consumed

        # Regular item
        return item
      end
    end
  end

  # Wrapper around stage output that routes to downstream queues
  class OutputQueue
    def initialize(stage, downstream_queues, runtime_edges, stage_stats: nil)
      @stage = stage
      @downstream_queues = downstream_queues # Array of Queue objects
      @runtime_edges = runtime_edges         # Track dynamic routing (keyed by Stage objects)
      @stage_stats = stage_stats             # Stats object for tracking (optional)
      @to_cache = {}                         # Memoization cache for .to() results
    end

    # Check if shutdown has been requested
    # Producers can use this to exit early and save work
    def shutdown?
      @stage.root_pipeline&.shutdown_requested? || false
    end

    # Request graceful shutdown of the pipeline
    # @param force [Boolean] If true, forces immediate shutdown
    def shutdown!(force: false)
      @stage.root_pipeline&.request_shutdown(force: force)
    end

    # Send item to all downstream stages
    # No-op after shutdown (silently drops items)
    def <<(item)
      return self if shutdown?

      @downstream_queues.each { |queue| queue << item }
      @stage_stats&.increment_produced # Track in stats directly
      self
    end

    # Magic sauce: explicit routing to specific stage
    # Returns a memoized OutputQueue that routes only to that stage
    # target can be Stage object or name
    def to(target)
      # Return cached instance if available (cache by original key for user convenience)
      return @to_cache[target] if @to_cache.key?(target)

      # Resolve target to Stage object if it's a name
      # Use StageRegistry for cross-pipeline lookup
      target_stage = task.stage_registry.find(target, from_pipeline: pipeline)
      raise ArgumentError.new("Unknown target stage: #{target}") unless target_stage

      # Look up queue by Stage object using Task's queue registry
      target_queue = task.find_queue(target_stage)
      raise ArgumentError.new("Unknown target stage: #{target} (resolved to #{target_stage.name})") unless target_queue

      # Track this as a runtime edge for END signal handling
      # Ensure the entry exists before adding to it (important for fork contexts)
      @runtime_edges[@stage] ||= Set.new
      @runtime_edges[@stage].add(target_stage)

      # Create and cache the OutputQueue for this target
      @to_cache[target] = OutputQueue.new(
        @stage,
        [target_queue],
        @runtime_edges,
        stage_stats: @stage_stats
      )
    end

    # Convert to proc for yield syntax
    # Allows: yield(item) or yield(item, to: :stage_name)
    def to_proc
      @to_proc ||= proc do |item, to: nil|
        if to
          # Route to specific stage
          self.to(to) << item
        else
          # Route to all downstream stages
          self << item
        end
      end
    end

    private

    def pipeline
      @stage.pipeline
    end

    def task
      pipeline&.task
    end
  end

  # IPC-backed input queue that reads items from parent via IPC pipe
  # Used by IpcForkPoolExecutor workers to receive items from parent process
  class IpcInputQueue
    def initialize(pipe_reader, stage)
      @pipe_reader = pipe_reader
      @stage = stage
      @buffer = []
    end

    def pop
      # Return buffered item if available
      return @buffer.shift unless @buffer.empty?

      # Read from IPC pipe
      loop do
        message = Marshal.load(@pipe_reader) # rubocop:disable Security/MarshalLoad

        case message[:type]
        when :item
          return message[:item]
        when :routed_item
          # Item targeted at specific nested stage - return with routing metadata
          return RoutedItem.new(message[:target_stage], message[:item])
        when :end_of_stage, :shutdown
          return EndOfStage.new(@stage)
        end
      end
    rescue IOError
      # Pipe closed, return EndOfStage
      EndOfStage.new(@stage)
    end
  end

  # IPC output queue with routing metadata for explicit routing via .to()
  # Wraps results with target stage information for parent to route correctly.
  class IpcRoutedOutputQueue
    include IpcOutputBehavior

    def initialize(pipe_writer, stage_stats, target_stage)
      @pipe_writer = pipe_writer
      @stage_stats = stage_stats
      @target_stage = target_stage
      @shutdown_requested = false
    end

    def <<(item)
      ipc_send_with_recovery(type: :routed_result, target: @target_stage, result: item)
      self
    end
  end

  # Output queue wrapper for IPC fork executors that sends items via pipe
  class IpcOutputQueue
    include IpcOutputBehavior

    def initialize(pipe_writer, stage_stats)
      @pipe_writer = pipe_writer
      @stage_stats = stage_stats
      @shutdown_requested = false
    end

    def <<(item)
      # Handle special cases that need different message types
      if item.nil?
        ipc_send(type: :no_result)
        @stage_stats&.increment_produced
      elsif item.is_a?(Minigun::EndOfStage)
        # EndOfStage contains Stage objects which aren't marshalable
        ipc_send(type: :end_of_stage)
        @stage_stats&.increment_produced
      else
        ipc_send_with_recovery(type: :result, result: item)
      end
      self
    end

    def to(target_stage)
      # For IPC workers, routing must be encoded in the result
      IpcRoutedOutputQueue.new(@pipe_writer, @stage_stats, target_stage)
    end

    def to_proc
      proc { |item, to: nil| self << item } # rubocop:disable Lint/UnusedBlockArgument
    end
  end
end
