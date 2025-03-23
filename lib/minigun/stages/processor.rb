# frozen_string_literal: true

module Minigun
  module Stages
    # Unified processor stage for all pipeline stages
    class Processor < Base
      # ResultWrapper class provides a simple wrapper for results that don't respond to wait
      ResultWrapper = Struct.new(:wait, :value)

      def initialize(name, pipeline, options = {})
        super
        @processed_count = Concurrent::AtomicFixnum.new(0)
        @failed_count = Concurrent::AtomicFixnum.new(0)
        @emitted_count = Concurrent::AtomicFixnum.new(0)

        # Set configuration with defaults
        @threads = options[:threads] || options[:max_threads] || 5
        @processes = options[:processes] || options[:max_processes] || 2
        @max_retries = options[:max_retries] || 3
        @batch_size = options[:batch_size] || 100

        @thread_pool = Concurrent::FixedThreadPool.new(@threads)

        # Get the block from the task
        @block = nil
        @block = @task.stage_blocks[name.to_sym] if @task.stage_blocks[name.to_sym]

        # Initialize fork implementation if needed
        fork_type = options[:fork] || options[:type]
        return unless %i[cow ipc].include?(fork_type)

        init_fork_implementation(fork_type)
      end

      # Process a single item
      def process(item)
        # Process the item and emit result(s)
        result = execute_block(item)

        # Track processing
        @processed_count.increment

        # If result is not explicitly nil, emit it
        # This allows processors to filter by returning nil
        emit(result) unless result.nil?

        # Return the result
        result
      rescue StandardError => e
        @failed_count.increment
        error("[Minigun:#{@job_id}][Stage:#{@name}] Error processing item: #{e.class}: #{e.message}\n#{e.backtrace.join("\n")}")
        raise e
      end

      # Shutdown the processor stage
      def shutdown
        # Shut down the thread pool if it exists
        if @thread_pool
          @thread_pool.shutdown
          @thread_pool.wait_for_termination(30)
        end

        # Call on_finish hook
        on_finish

        # Return stats
        {
          processed: @processed_count.value,
          failed: @failed_count.value,
          emitted: @emitted_count.value
        }
      end

      private

      # Execute the stage block with the given item
      def execute_block(item)
        if @block
          if @block.arity == 0
            # If block takes no arguments, use instance_eval
            @context.instance_exec do
              # Make the item available as an instance variable
              @item = item
              instance_eval(&@block)
            end
          else
            # Otherwise call with the item as argument
            @context.instance_exec(item, &@block)
          end
        else
          # Default implementation just passes the item through
          item
        end
      end

      # Initialize appropriate fork implementation based on type
      def init_fork_implementation(fork_type)
        case fork_type
        when :cow
          # Get the module as a constant
          cow_module = Minigun::Stages.const_get(:CowFork)
          extend cow_module
        when :ipc
          # Get the module as a constant
          ipc_module = Minigun::Stages.const_get(:IpcFork)
          extend ipc_module
        end
      end
    end
  end
end
