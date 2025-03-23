# frozen_string_literal: true

require 'concurrent'
require 'ostruct'

module Minigun
  module Stages
    # Unified processor stage that can function with different roles 
    # (producer or processor) based on configuration
    class Processor < Base
      # ResultWrapper class provides a simple wrapper for results that don't respond to wait
      ResultWrapper = Struct.new(:wait, :value)

      def initialize(name, pipeline, options = {})
        super
        @processed_count = Concurrent::AtomicFixnum.new(0)
        @failed_count = Concurrent::AtomicFixnum.new(0)
        @emitted_count = Concurrent::AtomicFixnum.new(0)

        @is_producer = options[:is_producer] || false

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
        if %i[cow ipc].include?(fork_type)
          init_fork_implementation(fork_type)
        end
      end

      # Process a single item
      def process(item)
        if @is_producer
          # For producer role, the block is called without any arguments
          # and it's expected to call produce() to generate items
          process_as_producer(item)
        else
          # For processor roles, the block is called with each item
          process_as_processor(item)
        end
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

      # Process item as a producer role (ignore input item, generate outputs)
      def process_as_producer(_item)
        # Prepare the context for producer
        Thread.current[:minigun_queue] = []

        begin
          # Call the block
          if @block
            # Execute in the context using instance_exec
            @context.instance_exec(&@block)
          else
            # Default implementation just returns nil
            nil
          end

          # Get the produced items
          items = Thread.current[:minigun_queue]

          # If there are items in the queue, emit them
          items.each { |produced_item| emit(produced_item) }

          @processed_count.increment
          @emitted_count.increment(items.size)

          # Return number of items produced
          items.size
        rescue StandardError => e
          @failed_count.increment
          error("[Minigun:#{@job_id}][Stage:#{@name}] Error in producer role: #{e.class}: #{e.message}\n#{e.backtrace.join("\n")}")
          raise e
        end
      end

      # Process item as a processor role (transform input)
      def process_as_processor(item)
        # Call the block with the item
        result = if @block
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
