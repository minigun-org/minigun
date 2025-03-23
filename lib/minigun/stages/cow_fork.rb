# frozen_string_literal: true

require 'concurrent'
require 'securerandom'
require 'yaml'

module Minigun
  module Stages
    # Implementation of Copy-On-Write fork behavior
    class CowFork < Base
      attr_reader :name, :job_id, :processes, :threads, :block

      def initialize(name, pipeline, options = {})
        super
        @processed_count = Concurrent::AtomicFixnum.new(0)
        @failed_count = Concurrent::AtomicFixnum.new(0)
        @emitted_count = Concurrent::AtomicFixnum.new(0)

        # Set configuration with defaults - use the values from options
        @max_threads = options[:max_threads] || options[:threads] || 5
        @max_retries = options[:max_retries] || 3
        @max_processes = options[:max_processes] || options[:processes] || 2
        @batch_size = options[:batch_size] || 100
        @accumulator_max_queue = options[:accumulator_max_queue] || (@batch_size * 10)

        # Initialize child process tracking
        @child_processes = []
        @process_mutex = Mutex.new

        # Initialize accumulator
        @accumulator = Hash.new { |h, k| h[k] = [] }

        # Get the block for this stage from the task
        @stage_block = nil

        # Check stage blocks directly 
        @stage_block = @task.stage_blocks[name.to_sym] if @task.respond_to?(:stage_blocks) && @task.stage_blocks[name.to_sym]

        # Fallback to a default implementation
        @stage_block ||= proc { |items| items }
      end

      def run
        # Nothing to do on startup
      end

      def process(item)
        # Get the type of the item
        type = item.class.name
        items = @accumulator[type]

        # Add to the accumulator
        items << item

        # If we've reached the batch size, process the batch
        process_batch(type) if items.size >= @batch_size

        # If the total accumulator size is too large, process the largest batch
        process_largest_batch if accumulator_size >= @accumulator_max_queue

        # Don't return anything to avoid chaining
        nil
      end

      def shutdown
        # Process all remaining items in accumulator
        @accumulator.each_key do |type|
          process_batch(type) unless @accumulator[type].empty?
        end

        # Wait for all child processes to complete
        wait_for_child_processes if @process_mutex

        # Shut down thread pool if it exists
        if @thread_pool
          @thread_pool.shutdown
          @thread_pool.wait_for_termination
        end

        # Return processing statistics
        {
          processed: @processed_count.value,
          failed: @failed_count.value,
          emitted: @emitted_count.value
        }
      end

      private

      def fork_to_process(items)
        # Wait if we've reached max processes
        wait_for_available_process_slot if @child_processes.size >= @max_processes

        # Start a new process if forking is available and fork mode allows
        if Process.respond_to?(:fork) && @fork_mode != :never
          # Create a pipe for parent-child communication
          read_pipe, write_pipe = IO.pipe

          pid = Process.fork do
            # In child process
            read_pipe.close

            # Run any before_fork hooks
            @task.run_hooks(:before_fork, @context) if @task.respond_to?(:run_hooks)

            # Set this process title for easier identification
            Process.setproctitle("minigun-cow-#{@name}-#{Process.pid}") if Process.respond_to?(:setproctitle)

            # Process the items
            results = process_items_in_child(items)

            # Send results back to parent
            write_pipe.write(Marshal.dump(results))
            write_pipe.close

            # Run any after_fork hooks
            @task.run_hooks(:after_fork, @context) if @task.respond_to?(:run_hooks)

            # Exit cleanly
            exit!(0)
          rescue StandardError => e
            # Handle errors in child process
            write_pipe.write(Marshal.dump({ error: e.message, backtrace: e.backtrace }))
            write_pipe.close
            exit!(1)
          end

          # In parent process
          write_pipe.close

          # Track the child process
          @process_mutex.synchronize do
            @child_processes << {
              pid: pid,
              pipe: read_pipe,
              start_time: Time.now,
              items_count: items.size
            }
          end
        else
          # If forking is not available or disabled, process using thread pool
          @thread_pool.post do
            results = process_items_directly(items)
            @processed_count.increment(results[:success] || 0)
            @failed_count.increment(results[:failed] || 0)
            @emitted_count.increment(results[:emitted] || 0) if results[:emitted] && results[:emitted] > 0
          rescue StandardError => e
            @logger.error("[Minigun:#{@job_id}][#{@name}] Thread pool error: #{e.message}")
            @logger.error("[Minigun:#{@job_id}][#{@name}] #{e.backtrace.join("\n")}") if e.backtrace
            @failed_count.increment(items.size)
          end
        end
      end

      def process_items_in_child(items)
        # Execute the fork block with the items


        # Store fork context for emit tracking
        Thread.current[:minigun_fork_context] = {
          emit_count: 0,
          success_count: 0,
          failed_count: 0
        }

        # Execute the fork block, which should call emit
        if @stage_block
          @context.instance_exec(items, &@stage_block)
        else
          # Default behavior if no block given - emit each item
          items.each do |item|
            emit(item)
          end
        end

        # Get counts from context
        context = Thread.current[:minigun_fork_context]
        success_count = context[:success_count]
        failed_count = context[:failed_count]
        emit_count = context[:emit_count]

        # Return results
        {
          success: success_count || items.size,
          failed: failed_count || 0,
          emitted: emit_count || 0
        }
      rescue StandardError => e
        @logger.error("[Minigun:#{@job_id}][#{@name}] Error in child process: #{e.message}")
        @logger.error("[Minigun:#{@job_id}][#{@name}] #{e.backtrace.join("\n")}") if e.backtrace
        {
          success: 0,
          failed: items.size,
          error: e.message,
          backtrace: e.backtrace
        }
      end

      def process_items_directly(items)
        # Track stats locally

        # Set up context for tracking emits


        # Store fork context for emit tracking
        Thread.current[:minigun_fork_context] = {
          emit_count: 0,
          success_count: 0,
          failed_count: 0
        }

        # Execute the fork block, which should call emit
        if @stage_block
          @context.instance_exec(items, &@stage_block)
        else
          # Default behavior if no block given - emit each item
          items.each do |item|
            emit(item)
          end
        end

        # Get counts from context
        context = Thread.current[:minigun_fork_context]
        success_count = context[:success_count] || items.size
        failed_count = context[:failed_count] || 0
        emit_count = context[:emit_count] || 0

        # Return results
        {
          success: success_count,
          failed: failed_count,
          emitted: emit_count
        }
      rescue StandardError => e
        @logger.error("[Minigun:#{@job_id}][#{@name}] Error in direct processing: #{e.message}")
        @logger.error("[Minigun:#{@job_id}][#{@name}] #{e.backtrace.join("\n")}") if e.backtrace
        {
          success: 0,
          failed: items.size,
          error: e.message,
          backtrace: e.backtrace
        }
      end

      def wait_for_available_process_slot
        loop do
          # Check child processes and collect any that have finished
          check_child_processes

          # If we have room for another process, we're done
          break if @child_processes.size < @max_processes

          # Sleep briefly before checking again
          sleep(0.1)
        end
      end

      def check_child_processes
        @process_mutex.synchronize do
          @child_processes.reject! do |child|
            # Check if the process has finished
            status = begin
              Process.waitpid(child[:pid], Process::WNOHANG)
            rescue Errno::ECHILD
              child[:pid] # Process doesn't exist anymore
            end

            if status
              # Process has finished, read the results
              begin
                results = Marshal.load(child[:pipe].read)
                child[:pipe].close

                # Check for errors in child
                if results[:error]
                  @logger.error("[Minigun:#{@job_id}][#{@name}] Child process error: #{results[:error]}")
                  @logger.error("[Minigun:#{@job_id}][#{@name}] #{results[:backtrace].join("\n")}") if results[:backtrace]
                  @failed_count.increment(child[:items_count])
                else
                  # Update statistics
                  @processed_count.increment(results[:success] || 0)
                  @failed_count.increment(results[:failed] || 0)
                  @emitted_count.increment(results[:emitted] || 0) if results[:emitted] && results[:emitted] > 0
                end
              rescue EOFError, TypeError, ArgumentError => e
                # Error reading from pipe
                @logger.error("[Minigun:#{@job_id}][#{@name}] Error reading from child pipe: #{e.message}")
                @failed_count.increment(child[:items_count])
              end

              # Remove from list
              true
            else
              # Process still running
              false
            end
          end
        end
      end

      def wait_for_child_processes
        @process_mutex.synchronize do
          return if @child_processes.empty?

          @logger.info("[Minigun:#{@job_id}][#{@name}] Waiting for #{@child_processes.size} child processes to finish")
        end

        # Wait for all child processes to complete
        loop do
          @process_mutex.synchronize do
            break if @child_processes.empty?
          end

          # Check child processes and collect any that have finished
          check_child_processes

          # Sleep briefly before checking again
          sleep(0.1)
        end
      end

      # Get the total size of all accumulated items
      def accumulator_size
        @accumulator.values.sum(&:size)
      end

      # Process the largest batch in the accumulator
      def process_largest_batch
        return if @accumulator.empty?

        # Find the type with the most items
        type = @accumulator.max_by { |_, items| items.size }.first
        process_batch(type)
      end

      # Process a batch of items of a specific type
      def process_batch(type)
        # Get the items to process
        items = @accumulator[type]
        return if items.empty?

        # Clear the batch
        @accumulator[type] = []

        # If forking is available, use it
        if Process.respond_to?(:fork)
          process_batch_with_fork(items)
        else
          # Fallback to direct processing
          process_items_directly(items)
        end
      end

      # Process items in a forked process
      def process_batch_with_fork(items)
        # Create a pipe for results
        rd, wr = IO.pipe

        # Fork a new process
        pid = Process.fork do
          # Close read end in child
          rd.close

          # Process the items
          result = process_items_directly(items)

          # Send results back to parent
          Marshal.dump(result, wr)
          wr.close

          # Exit the forked process
          exit!(0)
        end

        # Close write end in parent
        wr.close

        # Wait for the child process
        Process.wait(pid)

        # Read results from pipe
        result = Marshal.load(rd)
        rd.close

        # Update stats based on child process results
        @processed_count.increment(result[:success] || 0)
        @failed_count.increment(result[:failed] || 0)
        @emitted_count.increment(result[:emitted] || 0)
      end
    end
  end
end
