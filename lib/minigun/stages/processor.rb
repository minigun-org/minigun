# frozen_string_literal: true

require 'concurrent'
require 'ostruct'

module Minigun
  module Stages
    # Unified processor stage that can function as producer, processor, or consumer
    # based on configuration
    class Processor < Base
      # ResultWrapper class provides a simple wrapper for results that don't respond to wait
      ResultWrapper = Struct.new(:wait, :value)

      def initialize(name, pipeline, options = {})
        super
        @processed_count = Concurrent::AtomicFixnum.new(0)
        @failed_count = Concurrent::AtomicFixnum.new(0)
        @emitted_count = Concurrent::AtomicFixnum.new(0)
        @stage_role = options[:stage_role] || :processor

        # Set configuration with defaults
        @threads = options[:threads] || options[:max_threads] || 5
        @processes = options[:processes] || options[:max_processes] || 2
        @max_retries = options[:max_retries] || 3
        @batch_size = options[:batch_size] || 100

        @thread_pool = Concurrent::FixedThreadPool.new(@threads)

        # Get the processor block from the task
        @block = nil
        @block = @task.processor_blocks[name.to_sym] if @task.processor_blocks[name.to_sym]

        # For consumers, initialize fork implementation if needed
        return unless @stage_role == :consumer

        # Support both fork: and type: parameter syntax
        fork_type = options[:fork] || options[:type]
        return unless %i[cow ipc].include?(fork_type)

        init_fork_implementation(fork_type)
      end

      # Process a single item
      def process(item)
        # Run appropriate processing based on stage role
        case @stage_role
        when :producer
          # For producers, the block is called without any arguments
          # and it's expected to call produce() to generate items
          process_as_producer(item)
        when :processor
          # For processors, the block is called with each item
          # and expected to call emit() to send to next stage
          process_as_processor(item)
        when :consumer
          # For consumers, the block is called with each item/batch
          # and not expected to emit anything further
          process_as_consumer(item)
        else
          raise "Unknown stage role: #{@stage_role}"
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

      # Process item as a producer (ignore input item, generate outputs)
      def process_as_producer(_item)
        # Prepare the context for producer
        Thread.current[:minigun_queue] = []

        begin
          # Call the processor block
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
          error("[Minigun:#{@job_id}][Producer:#{@name}] Error: #{e.class}: #{e.message}\n#{e.backtrace.join("\n")}")
          raise e
        end
      end

      # Process item as a processor (transform input to output)
      def process_as_processor(item)
        # Call the processor block with the item
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
        error("[Minigun:#{@job_id}][Processor:#{@name}] Error processing item: #{e.class}: #{e.message}\n#{e.backtrace.join("\n")}")
        raise e
      end

      # Process item as a consumer (take input, produce no output)
      def process_as_consumer(item)
        # Call the consumer block with the item
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
        end

        @processed_count.increment
        nil # Consumers don't return a value
      rescue StandardError => e
        @failed_count.increment
        error("[Minigun:#{@job_id}][Consumer:#{@name}] Error consuming item: #{e.class}: #{e.message}\n#{e.backtrace.join("\n")}")
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
