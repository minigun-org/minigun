# frozen_string_literal: true

require 'concurrent'

module Minigun
  module Stages
    # Accumulator stage that collects items and batches them
    class Accumulator < Base
      def initialize(name, pipeline, options = {})
        super
        @batch_size = options[:batch_size] || 100
        @flush_interval = options[:flush_interval] || 5
        @max_batch_size = options[:max_batch_size] || 500
        @processed_count = Concurrent::AtomicFixnum.new(0)
        @emitted_count = Concurrent::AtomicFixnum.new(0)
        @accumulated_count = Concurrent::AtomicFixnum.new(0)
        @batches = {}
        @flush_timer = nil

        # Get the stage block
        @block = nil
        
        # Check stage blocks directly
        @block = @task.stage_blocks[name.to_sym] if @task.respond_to?(:stage_blocks) && @task.stage_blocks[name.to_sym]
        
        # For backward compatibility
        if @block.nil? && @task.respond_to?(:accumulator_blocks) && @task.accumulator_blocks
          @block = @task.accumulator_blocks[name.to_sym]
        end
      end

      # Run method starts the flush timer
      def run
        on_start
        @flush_timer = Concurrent::TimerTask.new(execution_interval: @flush_interval) do
          flush_all_batches
        end
        @flush_timer.execute
      end

      # Process a single item
      def process(item)
        # We track processed count
        @processed_count.increment
        @accumulated_count.increment

        # Call the block if provided, otherwise use default accumulation
        if @block
          # User-defined accumulation logic
          @context.instance_exec(item, &@block)
        else
          # Default accumulation by type
          key = determine_batch_key(item)
          add_to_batch(key, item)
        end
      end

      # Shutdown the stage and flush any remaining batches
      def shutdown
        # Shutdown the timer if we have one
        @flush_timer&.shutdown

        # Flush all batches
        flush_all_batches

        # Call on_finish hook
        on_finish

        # Return stats
        {
          processed: @processed_count.value,
          emitted: @emitted_count.value,
          accumulated: @accumulated_count.value
        }
      end

      # Force emission of all batches
      def flush
        flush_all_batches
      end

      private

      # Determine the batch key for an item (defaults to its class name)
      def determine_batch_key(item)
        item.class.name
      end

      # Add an item to a batch
      def add_to_batch(key, item)
        # Initialize the batch if needed
        @batches[key] ||= []
        @batches[key] << item

        # Check if we should flush this batch
        flush_batch_if_needed(key)
      end

      # Check if a batch should be flushed
      def flush_batch_if_needed(key)
        # Flush if the batch has reached max batch size
        return unless @batches[key] && @batches[key].size >= @max_batch_size

        debug("Flushing batch of #{@batches[key].size} items of type #{key}")
        flush_batch_items(key, @batches[key])
        @batches[key] = []
      end

      # Flush all batches that have items
      def flush_all_batches
        @batches.each do |key, items|
          next if items.empty?

          # Flush the batch
          flush_batch_items(key, items)
          @batches[key] = []
        end
      end

      # Flush items from a specific batch
      def flush_batch_items(key, items)
        return if items.empty?

        # Split into chunks of batch_size and emit each
        items.each_slice(@batch_size) do |batch_items|
          emit(batch_items, key.to_sym)
          @emitted_count.increment
        end
      end
    end
  end
end
