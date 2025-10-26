# frozen_string_literal: true

module Minigun
  module Execution
    # Manages a pool of execution contexts for resource management
    class ContextPool
      attr_reader :type, :max_size

      def initialize(type:, max_size:)
        @type = type  # :inline, :thread, :fork, :ractor
        @max_size = max_size
        @active_contexts = []
        @available_contexts = []
        @mutex = Mutex.new
        @counter = 0
      end

      # Get an available context or create one
      def acquire(name = nil)
        @mutex.synchronize do
          context = @available_contexts.pop || create_context(name)
          @active_contexts << context
          context
        end
      end

      # Return context to pool (reuse inline, fresh threads/processes)
      def release(context)
        @mutex.synchronize do
          @active_contexts.delete(context)
          
          # Only reuse inline contexts (no concurrency concerns)
          # Threads/processes are always fresh to prevent state pollution
          if @type == :inline && @available_contexts.size < @max_size
            @available_contexts << context
          end
        end
      end

      # Wait for all active contexts to complete
      def join_all
        contexts = @mutex.synchronize { @active_contexts.dup }
        contexts.each(&:join)
        @mutex.synchronize do
          @active_contexts.clear
          @available_contexts.clear
        end
      end

      # Terminate all active contexts
      def terminate_all
        contexts = @mutex.synchronize { @active_contexts.dup }
        contexts.each(&:terminate)
        @mutex.synchronize do
          @active_contexts.clear
          @available_contexts.clear
        end
      end

      # Get count of active contexts
      def active_count
        @mutex.synchronize { @active_contexts.size }
      end

      # Check if pool is at capacity
      def at_capacity?
        active_count >= @max_size
      end

      private

      def create_context(name)
        @counter += 1
        full_name = name ? "#{name}-#{@counter}" : "ctx-#{@counter}"
        Execution.create_context(@type, full_name)
      end
    end
  end
end

