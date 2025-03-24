# frozen_string_literal: true

require_relative 'base'

module Minigun
  module Stages
    # Implementation of the accumulator stage behavior
    class Accumulator < Base
      def initialize(name, pipeline, options = {})
        super
        @flush_proc = options[:flush]
        @accumulator = {}
        @accumulator_mutex = Mutex.new
      end

      def process(item)
        # Get the type of the item
        type = item.class.name

        # Accumulate the item by type
        @accumulator_mutex.synchronize do
          @accumulator[type] ||= []
          @accumulator[type] << item

          # Check if we should flush
          if should_flush?(type)
            flush(type)
          end
        end
      end

      def shutdown
        # Flush any remaining items
        @accumulator_mutex.synchronize do
          @accumulator.each_key do |type|
            flush(type) unless @accumulator[type].empty?
          end
        end
      end

      private

      def should_flush?(type)
        return false unless @accumulator[type] && !@accumulator[type].empty?

        # If the user provided a flush proc, use it
        if @flush_proc
          @flush_proc.call(type: type, items: @accumulator[type].dup)
        else
          # Default is to flush when we have 100 items
          @accumulator[type].size >= 100
        end
      end

      def flush(type)
        # Get the items to emit
        items = @accumulator[type].dup

        # Clear the accumulator for this type
        @accumulator[type] = []

        # Emit the items as a batch
        emit(items)
      end
    end
  end
end
