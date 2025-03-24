# frozen_string_literal: true

module Minigun
  module Examples
    # Example of a custom accumulator with lifecycle hooks
    class CustomAccumulator < Minigun::Stages::Base
      # Define a class-level before_start hook
      before_start do
        @processed_items = []
        @batch_count = 0
        debug("Starting CustomAccumulator with batch size #{@batch_size}")
        
        # Start a periodic flush timer
        @flush_timer = Concurrent::TimerTask.new(execution_interval: @flush_interval) do
          # Force flush every interval
          flush_batch if @processed_items.any?
        end
        @flush_timer.execute
      end
      
      # Define a class-level after_finish hook
      after_finish do
        # Shutdown the timer
        @flush_timer&.shutdown
        
        # Flush any remaining items
        flush_batch if @processed_items.any?
        debug("CustomAccumulator finished: Processed #{@batch_count} batches")
      end
      
      def initialize(name, pipeline, options = {})
        super
        @batch_size = options[:batch_size] || 10
        @flush_interval = options[:flush_interval] || 5
        
        # You can also add instance-specific hooks during initialization
        after_finish do
          debug("Instance-specific cleanup for #{@name}")
        end
      end
      
      # Process an item by adding it to our internal buffer
      def process(item)
        super
        @processed_items ||= []
        @processed_items << item
        
        # Flush the batch if we've reached the batch size
        flush_batch if @processed_items.size >= @batch_size
      end
      
      private
      
      # Flush the current batch of items
      def flush_batch
        return if @processed_items.empty?
        
        items = @processed_items.dup
        @processed_items.clear
        @batch_count += 1
        
        debug("Flushing batch ##{@batch_count} with #{items.size} items")
        emit(items)
      end
    end
  end
end 