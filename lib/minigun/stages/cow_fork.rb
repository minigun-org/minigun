# frozen_string_literal: true

require_relative 'base'

module Minigun
  module Stages
    # Implementation of the Copy-On-Write fork stage behavior
    class CowFork < Base
      attr_reader :name, :job_id, :processes, :threads, :block, :child_processes, :process_stats

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
        @child_processes = {}
        @process_mutex = Mutex.new

        # Initialize accumulator
        @accumulator = {}

        # Get the block for this stage from the task
        @stage_block = nil

        # Check stage blocks directly
        @stage_block = @task.stage_blocks[name.to_sym] if @task.respond_to?(:stage_blocks) && @task.stage_blocks[name.to_sym]

        # Fallback to a default implementation
        @stage_block ||= proc { |items| items }

        # Stats
        @items_processed = 0
        @items_failed = 0
        @batches_processed = 0
        @fork_count = 0

        @processes = options[:processes] || 2
        @workers = []
      end

      def run
        # Nothing to do on startup
      end

      def process(item)
        # In a real implementation, this would fork processes using copy-on-write
        # For now, just process the item directly
        puts "[COW Fork] Processing item: #{item}"
        emit(item)
      end

      def shutdown
        # Process all remaining items in accumulator
        @accumulator.each_key do |type|
          process_batch(type) unless @accumulator[type].empty?
        end

        # Wait for all child processes to complete
        wait_for_child_processes

        # Log final stats
        @logger.info("[Minigun:#{@job_id}][#{@name}] Fork stage complete. #{@items_processed} items processed in #{@batches_processed} batches with #{@fork_count} forks.")

        # Return stats for reporting
        {
          items_processed: @items_processed,
          items_failed: @items_failed,
          batches_processed: @batches_processed,
          fork_count: @fork_count
        }
      end

      def stop
        # Stop all worker processes
        @workers.each(&:stop)
        super
      end

      private

      def fork_to_process(items)
        # Wait if we've reached max processes
        wait_for_available_process_slot if @child_processes.size >= @max_processes

        # Increment fork count
        @fork_count += 1

        # Use the task's run_hook method for the around_fork hook
        @task.run_hook :fork, @context do
          # Set up pipe for result transmission
          read_pipe, write_pipe = IO.pipe

          # Fork a new process
          pid = Process.fork do
            # Close the read end in the child
            read_pipe.close

            # Clean up any resources that shouldn't be shared
            @process_mutex = nil
            @child_processes = nil

            # Set this process title for easier identification
            Process.setproctitle("minigun-cow-#{@name}-#{Process.pid}") if Process.respond_to?(:setproctitle)

            # Process the items directly - we already have them in memory
            begin
              # Process items and get results
              results = process_items_in_child(items)

              # Log completion
              @logger.info("[Minigun:#{@job_id}][#{@name}] Child process completed: #{results[:success]} processed, #{results[:failed]} failed")

              # Exit with success code
              exit!(0)
            rescue StandardError => e
              # Handle errors in child process
              @logger.error("[Minigun:#{@job_id}][#{@name}] Error in child process: #{e.message}")
              @logger.error("[Minigun:#{@job_id}][#{@name}] #{e.backtrace.join("\n")}") if e.backtrace
              exit!(1)
            end
          end

          # Close the write end in the parent
          write_pipe.close

          # Add to process tracking
          @process_mutex.synchronize do
            @child_processes[pid] = {
              pid: pid,
              started_at: Time.now,
              items: items.size,
              pipe: read_pipe
            }
          end

          # Log the fork
          @logger.info("[Minigun:#{@job_id}][#{@name}] Forked process #{pid} to handle #{items.size} items")

          # Start a thread to monitor this process
          Thread.new do
            begin
              # Wait for the process to complete
              _, status = Process.waitpid2(pid)

              # Update stats
              @process_mutex.synchronize do
                if status.success?
                  @process_stats[:success] += 1
                  @items_processed += items.size
                else
                  @process_stats[:failed] += 1
                  @items_failed += items.size
                end

                # Remove from tracking
                @child_processes.delete(pid)
              end

              # Close the pipe
              read_pipe.close
            rescue StandardError => e
              @logger.error("[Minigun:#{@job_id}][#{@name}] Error monitoring process #{pid}: #{e.message}")
            end
          end
        end
      end

      def process_items_in_child(items)
        # Store fork context for emit tracking
        Thread.current[:minigun_fork_context] = {
          emitted_items: []
        }

        # Set up child process - clean up any inherited threads/mutexes
        @thread_pool = Concurrent::FixedThreadPool.new(4)
        @processed_count = 0
        @failed_count = 0

        # Process each item in the batch
        results = Concurrent::Array.new
        futures = []

        items.each_with_index do |item, index|
          futures << Concurrent::Future.execute(executor: @thread_pool) do
            begin
              # Process the item with the block
              @instance_context.instance_exec(item, &@stage_block)
              results[index] = { status: :success }
              @processed_count += 1
            rescue StandardError => e
              results[index] = { status: :error, error: e.message }
              @failed_count += 1
              @logger.error("[Minigun:#{@job_id}][#{@name}:#{Process.pid}] Error processing item: #{e.message}")
            end
          end
        end

        # Wait for all futures to complete
        futures.each(&:wait)

        # Shut down thread pool
        @thread_pool.shutdown
        @thread_pool.wait_for_termination

        # Return results
        {
          success: @processed_count,
          failed: @failed_count
        }
      end

      def process_items_directly(items)
        # Track stats locally
        processed_count = 0
        failed_count = 0

        # Store fork context for emit tracking
        Thread.current[:minigun_fork_context] = {
          emitted_items: []
        }

        # Set up a thread pool
        thread_pool = Concurrent::FixedThreadPool.new(4)
        futures = []

        # Process each item in parallel
        items.each do |item|
          futures << Concurrent::Future.execute(executor: thread_pool) do
            begin
              # Process the item with the block
              @instance_context.instance_exec(item, &@stage_block)
              processed_count += 1
            rescue StandardError => e
              failed_count += 1
              @logger.error("[Minigun:#{@job_id}][#{@name}] Error processing item: #{e.message}")
            end
          end
        end

        # Wait for all futures to complete
        futures.each(&:wait)

        # Shut down thread pool
        thread_pool.shutdown
        thread_pool.wait_for_termination

        # Update stats
        @items_processed += processed_count
        @items_failed += failed_count

        # Return stats for this batch
        {
          success: processed_count,
          failed: failed_count
        }
      end

      def wait_for_available_process_slot
        loop do
          # Check if any processes have completed
          check_child_processes

          # Check if we have room now
          break if @child_processes.size < @max_processes

          # Sleep briefly and try again
          sleep 0.1
        end
      end

      def check_child_processes
        @process_mutex.synchronize do
          # Check each process
          @child_processes.each_key do |pid|
            # Check if the process has exited with a non-blocking wait
            begin
              wpid, status = Process.waitpid2(pid, Process::WNOHANG)
              
              next unless wpid # Process still running

              # Process has exited
              if status.success?
                @process_stats[:success] += 1
              else
                @process_stats[:failed] += 1
              end

              # Remove from tracking
              @child_processes.delete(pid)
            rescue Errno::ECHILD
              # Process already gone
              @child_processes.delete(pid)
            end
          end
        end
      end

      def wait_for_child_processes
        @process_mutex.synchronize do
          return if @child_processes.empty?
          
          # Log that we're waiting
          @logger.info("[Minigun:#{@job_id}][#{@name}] Waiting for #{@child_processes.size} child processes to complete...")
          
          # Get all PIDs before releasing the mutex
          pids = @child_processes.keys
        end

        # Wait for each process
        pids.each do |pid|
          begin
            # Wait for this process
            Process.waitpid(pid)
          rescue Errno::ECHILD
            # Process already gone
          end
        end

        # Clear out any remaining child processes
        @process_mutex.synchronize do
          @child_processes.clear
        end
      end

      # Get the total size of all accumulated items
      def accumulator_size
        @accumulator.values.sum(&:size)
      end

      # Check if any batch is ready for processing
      def batch_ready_for_processing?
        accumulator_size >= @min_batch_size
      end

      # Process the largest batch in the accumulator
      def process_largest_batch
        return if @accumulator.empty?

        # Find the type with the most items
        largest_type = @accumulator.max_by { |_, items| items.size }&.first
        
        # Process that batch
        process_batch(largest_type) if largest_type
      end

      # Process a batch of a specific type
      def process_batch(type)
        # Get the items to process
        items = @accumulator[type]
        return if items.nil? || items.empty?

        # Clear the accumulator for this type
        @accumulator[type] = []

        # Increment stats
        @batches_processed += 1

        # Process the batch
        if items.size >= @min_batch_size
          # For larger batches, use fork for parallel processing
          process_batch_with_fork(items)
        else
          # For small batches, process directly
          process_items_directly(items)
        end
      end

      # Process a batch using COW fork
      def process_batch_with_fork(items)
        # Force GC before forking to avoid unnecessary CoW pages
        GC.start

        # Fork to process the items
        fork_to_process(items)
      end
    end
  end
end
