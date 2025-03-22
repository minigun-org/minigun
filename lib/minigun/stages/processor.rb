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
        @block = pipeline.task.class._minigun_processor_blocks[name.to_sym] if pipeline.task.class.respond_to?(:_minigun_processor_blocks)

        # For consumers, initialize fork implementation if needed
        return unless @stage_role == :consumer

        # Support both fork: and type: parameter syntax
        fork_type = options[:fork] || options[:type]
        return unless %i[cow ipc].include?(fork_type)

        init_fork_implementation(fork_type)
      end

      # Initialize fork implementation for consumer role if needed
      def init_fork_implementation(type)
        if type == :cow
          require 'minigun/stages/cow_fork'
          @fork_impl = CowFork.new(@name, @pipeline, {
                                     logger: @logger,
                                     max_processes: @processes,
                                     max_threads: @threads
                                   })
        else # :ipc
          require 'minigun/stages/ipc_fork'
          @fork_impl = IpcFork.new(@name, @pipeline, {
                                     logger: @logger,
                                     max_processes: @processes,
                                     max_threads: @threads
                                   })
        end
      end

      def run
        # Different behavior based on stage role
        case @stage_role
        when :producer
          run_as_producer
        when :processor
          # Processors start automatically when items flow to them
        when :consumer
          # If using fork implementation, delegate to it
          @fork_impl.run if @fork_impl.respond_to?(:run)
        end
      end

      def process(item)
        # Only process items in processor/consumer roles
        return unless @stage_role == :processor || @stage_role == :consumer

        @processed_count.increment
        @logger.debug("Processing item: #{item.inspect}") if @config[:debug]

        retries = 0
        begin
          # Execute the processor block in the context of the task
          result = @task.instance_exec(item, &@block)

          # Create a pseudo-future if the result doesn't respond to wait
          # This will help with test compatibility
          if result.is_a?(Hash) && !result.respond_to?(:wait)
            original_result = result
            result = ResultWrapper.new(
              -> { original_result },
              -> { original_result }
            )
          end

          if @stage_role == :processor
            # Emit the result for processors
            emit(result.respond_to?(:value) ? result.value : result)
          end

          @emitted_count.increment if @stage_role == :processor
          @logger.debug "Processed item: #{item.inspect}" if @config[:debug]
        rescue StandardError => e
          @failed_count.increment

          # Implement retry logic
          retries += 1
          if retries <= @max_retries
            @logger.error "Error processing item (attempt #{retries}/#{@max_retries + 1}): #{e.message}"
            sleep_with_backoff(retries)
            retry
          else
            @logger.error "Error processing item: #{e.message}"
            @logger.error e.backtrace.join("\n") if e.backtrace
            raise e
          end
        end

        result
      end

      # Helper method to sleep with exponential backoff
      def sleep_with_backoff(retry_count)
        # Start with 0.1 second, then double for each retry with some jitter
        sleep_time = [0.1 * (2**(retry_count - 1)), 30].min * (0.5 + rand)
        sleep(sleep_time)
      end

      def shutdown
        # If this is a consumer with fork implementation, delegate
        return @fork_impl.shutdown if @stage_role == :consumer && @fork_impl

        # Shutdown thread pool
        @thread_pool.shutdown
        @thread_pool.wait_for_termination(30) # Wait up to 30 seconds

        # Return stats
        {
          processed: @processed_count.value,
          failed: @failed_count.value,
          emitted: @emitted_count.value
        }
      end

      # Run as a producer stage
      def run_as_producer
        return unless @block

        begin
          # Run the producer block to generate items
          @task.instance_exec(self, &@block)

          @logger.info("[Minigun:#{@job_id}][#{@name}] Producer finished, emitted #{@emitted_count.value} items")
        rescue StandardError => e
          @logger.error("[Minigun:#{@job_id}][#{@name}] Producer failed: #{e.message}")
          @logger.error(e.backtrace.join("\n")) if e.backtrace
          raise e
        end
      end

      # Override emit to track count
      def emit(item, queue = :default)
        super
        @emitted_count.increment
      end

      # Expose these attributes to fork implementation
      attr_reader :block, :threads, :processes, :max_retries, :batch_size, :stage_role

      # Methods used by fork implementation
      def increment_processed_count(count = 1)
        @processed_count.increment(count)
      end

      def increment_failed_count(count = 1)
        @failed_count.increment(count)
      end

      def increment_emitted_count(count = 1)
        @emitted_count.increment(count)
      end
    end
  end
end
