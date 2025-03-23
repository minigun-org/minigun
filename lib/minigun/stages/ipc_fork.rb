# frozen_string_literal: true

require 'concurrent'
require 'securerandom'
require 'yaml'

module Minigun
  module Stages
    # Implementation of IPC-style fork behavior
    class IpcFork < Base
      attr_reader :name, :job_id, :processes, :threads, :block

      def initialize(name, pipeline, config = {})
        super
        # Configuration - use existing instance variables if already set
        @max_processes = config[:processes] || config[:max_processes] || 2
        @max_threads = config[:threads] || config[:max_threads] || 5
        @max_retries = config[:max_retries] || 3
        @fork_mode = config[:fork_mode] || :auto

        # For compatibility with the processor interface
        @processes = @max_processes
        @threads = @max_threads

        # Initialize child process tracking
        @child_processes = []
        @process_mutex = Mutex.new

        # Create thread pool for non-forking mode
        @thread_pool = Concurrent::FixedThreadPool.new(@max_threads)

        # Statistics
        @processed_count = Concurrent::AtomicFixnum.new(0)
        @failed_count = Concurrent::AtomicFixnum.new(0)
        @emitted_count = Concurrent::AtomicFixnum.new(0)

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

      def process(items)
        items = [items] unless items.is_a?(Array)

        # Fork a child process to handle these items
        fork_to_process(items)
      end

      def shutdown
        # Wait for all child processes to complete
        wait_for_child_processes

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
            Process.setproctitle("minigun-ipc-#{@name}-#{Process.pid}") if Process.respond_to?(:setproctitle)

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
        # Execute the block directly without forking


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
    end
  end
end
