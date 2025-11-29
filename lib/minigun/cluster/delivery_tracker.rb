# frozen_string_literal: true

module Minigun
  module Cluster
    # Tracks in-flight items for at-least-once delivery semantics
    # Thread-safe tracking of items sent to workers, with retry support
    #
    # Uses monotonic sequence numbers for item IDs - safe because:
    # 1. Each executor instance has its own tracker
    # 2. Sequence is only used within a single pipeline run
    # 3. No cross-process/cross-machine ID coordination needed
    class DeliveryTracker
      # Represents a tracked item in-flight to a worker
      TrackedItem = Struct.new(:item, :worker_uri, :retries, :sent_at, keyword_init: true)

      attr_reader :max_retries

      def initialize(max_retries: 3)
        @max_retries = max_retries
        @mutex = Mutex.new
        @sequence = 0
        @in_flight = {}         # item_id -> TrackedItem
        @completed_ids = Set.new
        @retry_queue = Queue.new
      end

      # Generate a unique item ID (monotonic sequence, thread-safe)
      def generate_id
        @mutex.synchronize { @sequence += 1 }
      end

      # Track a new item being sent to a worker
      # Returns the item_id
      def track(item, worker_uri:)
        item_id = generate_id
        @mutex.synchronize do
          @in_flight[item_id] = TrackedItem.new(
            item: item,
            worker_uri: worker_uri,
            retries: 0,
            sent_at: Time.now
          )
        end
        item_id
      end

      # Record a successful completion
      # Returns true if this was a new completion, false if already completed (duplicate)
      def complete(item_id)
        @mutex.synchronize do
          return false if @completed_ids.include?(item_id)

          @completed_ids.add(item_id)
          @in_flight.delete(item_id)
          true
        end
      end

      # Record a failure - queues for retry if retries remaining
      # Returns :retry if queued for retry, :exhausted if max retries exceeded, :already_completed if duplicate
      def fail(item_id, error:)
        @mutex.synchronize do
          return :already_completed if @completed_ids.include?(item_id)

          tracked = @in_flight[item_id]
          return :not_found unless tracked

          if tracked.retries < @max_retries
            # Queue for retry
            @retry_queue << {
              item_id: item_id,
              item: tracked.item,
              retries: tracked.retries + 1
            }
            :retry
          else
            # Max retries exceeded
            @in_flight.delete(item_id)
            :exhausted
          end
        end
      end

      # Update tracking for a retry attempt
      def update_for_retry(item_id, item:, worker_uri:, retries:)
        @mutex.synchronize do
          @in_flight[item_id] = TrackedItem.new(
            item: item,
            worker_uri: worker_uri,
            retries: retries,
            sent_at: Time.now
          )
        end
      end

      # Get next item to retry (non-blocking)
      # Returns nil if no retries pending
      def next_retry
        @retry_queue.pop(true)
      rescue ThreadError
        nil
      end

      # Check if all items are completed (in-flight empty and no retries pending)
      def all_complete?
        @mutex.synchronize do
          @in_flight.empty? && @retry_queue.empty?
        end
      end

      # Number of items currently in-flight
      def in_flight_count
        @mutex.synchronize { @in_flight.size }
      end

      # Number of items completed
      def completed_count
        @mutex.synchronize { @completed_ids.size }
      end

      # Get stats
      def stats
        @mutex.synchronize do
          {
            in_flight: @in_flight.size,
            completed: @completed_ids.size,
            retries_pending: @retry_queue.size
          }
        end
      end
    end
  end
end
