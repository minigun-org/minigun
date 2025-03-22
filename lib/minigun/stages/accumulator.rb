# frozen_string_literal: true

require 'concurrent'

module Minigun
  module Stages
    # Accumulator stage that batches items before sending them to the next stage
    class Accumulator < Base
      def initialize(name, pipeline, config = {})
        super
        @accumulated_count = 0

        # Configuration
        @batch_size = config[:batch_size] || 100
        @flush_interval = config[:flush_interval] || 5 # seconds
        @max_batch_size = config[:max_batch_size] || 1000

        # Get custom accumulator block if defined
        @accumulator_block = @task.class._minigun_accumulator_blocks&.dig(name.to_sym)

        # Batching data structures
        @batches = Concurrent::Hash.new { |h, k| h[k] = [] }
        @batch_mutex = Mutex.new

        # Setup flush timer
        @flush_timer = Concurrent::TimerTask.new(
          execution_interval: @flush_interval,
          timeout_interval: @flush_interval * 2
        ) do
          flush_all_batches
        end
      end

      def run
        on_start
        @flush_timer.execute
      end

      def process(item)
        item_type = determine_batch_key(item)

        @batch_mutex.synchronize do
          @batches[item_type] << item
          @accumulated_count += 1

          # If we've reached max batch size for this type, flush it
          if @batches[item_type].size >= @max_batch_size
            # Get items to flush
            items = @batches[item_type]
            @batches[item_type] = []
            # Flush outside the mutex to avoid deadlock
            flush_batch_items(item_type, items)
          end
        end
      end

      def shutdown
        @flush_timer.shutdown
        flush_all_batches

        on_finish
        { accumulated: @accumulated_count }
      end

      private

      def determine_batch_key(item)
        # By default, batch by item class
        item.class.name
      end

      def flush_all_batches
        items_by_key = {}

        # Get all batches first
        @batch_mutex.synchronize do
          @batches.each do |key, items|
            if items.any?
              items_by_key[key] = items.dup
              @batches[key] = []
            end
          end
        end

        # Then flush them outside the mutex
        items_by_key.each do |key, items|
          flush_batch_items(key, items)
        end
      end

      def flush_batch(key)
        # Get items to flush
        items = nil
        @batch_mutex.synchronize do
          items = @batches[key]
          @batches[key] = []
        end

        # Flush outside the mutex
        flush_batch_items(key, items)
      end

      def flush_batch_items(key, items)
        return if items.empty?

        info("[Minigun:#{@job_id}][#{@name}] Flushing batch of #{items.size} #{key} items")

        # Send the batch to the next stage
        items.each_slice(@batch_size) do |slice|
          emit(slice)
        end
      end
    end
  end
end
