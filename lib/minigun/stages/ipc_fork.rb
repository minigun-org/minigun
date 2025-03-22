# frozen_string_literal: true

require 'concurrent'
require 'securerandom'
require 'yaml'

module Minigun
  module Stages
    # Implementation of IPC-style fork behavior
    class IpcFork
      attr_reader :name, :job_id, :processes, :threads, :block

      def initialize(name, pipeline, config = {})
        @name = name
        @pipeline = pipeline
        @task = pipeline.task
        @logger = config[:logger] || pipeline.instance_variable_get(:@logger)
        @job_id = pipeline.job_id

        # Configuration
        @max_processes = config[:processes] || config[:max_processes] || 2
        @max_threads = config[:threads] || config[:max_threads] || 5
        @max_retries = config[:max_retries] || 3
        @fork_mode = config[:fork_mode] || :auto

        # Safely get the processor block
        @block = nil
        @block = @task.class._minigun_processor_blocks[name.to_sym] if @task.class.respond_to?(:_minigun_processor_blocks)

        # Get the consumer block if available
        @consumer_block = nil
        if @task.class.respond_to?(:_minigun_consumer_blocks) && @task.class._minigun_consumer_blocks.is_a?(Hash)
          @consumer_block = @task.class._minigun_consumer_blocks[name.to_sym]
        elsif @task.class.respond_to?(:_minigun_consumer_block)
          @consumer_block = @task.class._minigun_consumer_block
        end

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
            @task.run_hooks(:before_fork)

            # Set this process title for easier identification
            Process.setproctitle("minigun-ipc-#{@name}-#{Process.pid}") if Process.respond_to?(:setproctitle)

            # Process the items
            results = process_items_in_child(items)

            # Send results back to parent
            write_pipe.write(Marshal.dump(results))
            write_pipe.close

            # Run any after_fork hooks
            @task.run_hooks(:after_fork)

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
        items = [items] unless items.is_a?(Array)

        # Execute the fork block with the items
        success_count = 0
        failed_count = 0

        begin
          # Store fork context for emit tracking
          Thread.current[:minigun_fork_context] = {
            emit_count: 0,
            success_count: 0,
            failed_count: 0
          }

          # Execute the fork block, which should call emit
          if @block
            @task.instance_exec(items, &@block)
          else
            # Default behavior if no block given - emit each item
            items.each do |item|
              @task.emit(item)
            end
          end

          # Get counts from context
          context = Thread.current[:minigun_fork_context]
          success_count = context[:success_count]
          failed_count = context[:failed_count]
          emit_count = context[:emit_count]

          @logger.info("[Minigun:#{@job_id}][#{@name}] IPC fork processed #{items.size} items, emitted #{emit_count}")
        rescue StandardError => e
          @logger.error("[Minigun:#{@job_id}][#{@name}] Error in IPC fork: #{e.message}")
          @logger.error(e.backtrace.join("\n")) if e.backtrace
          failed_count = items.size
        end

        {
          success: success_count,
          failed: failed_count,
          emitted: Thread.current[:minigun_fork_context][:emit_count] || 0
        }
      end

      def process_items_directly(items)
        items = [items] unless items.is_a?(Array)

        success_count = 0
        failed_count = 0

        Thread.current[:minigun_fork_context] = {
          emit_count: 0,
          success_count: 0,
          failed_count: 0
        }

        begin
          # Execute the fork block directly
          if @consumer_block
            @task.instance_exec(items, &@consumer_block)
          elsif @block
            @task.instance_exec(items, &@block)
          else
            # Default behavior
            items.each do |item|
              @task.emit(item)
            end
          end

          # Get results
          context = Thread.current[:minigun_fork_context]
          success_count = context[:success_count] || items.size
          emit_count = context[:emit_count] || 0

          # Update statistics
          @processed_count.increment(success_count)
          @emitted_count.increment(emit_count)

          @logger.info("[Minigun:#{@job_id}][#{@name}] Processed #{items.size} items directly, emitted #{emit_count}")
        rescue StandardError => e
          @logger.error("[Minigun:#{@job_id}][#{@name}] Error processing directly: #{e.class}: #{e.message}")
          @logger.error(e.backtrace.join("\n")) if e.backtrace
          failed_count = items.size
          @failed_count.increment(failed_count)
        end

        {
          success: success_count,
          failed: failed_count,
          emitted: Thread.current[:minigun_fork_context][:emit_count] || 0
        }
      end

      def wait_for_available_process_slot
        # Check for any completed processes
        check_finished_processes(non_blocking: true)

        # If still at max, wait for one to finish
        return unless @child_processes.size >= @max_processes

        check_finished_processes(non_blocking: false)
      end

      def check_finished_processes(non_blocking: false)
        options = non_blocking ? Process::WNOHANG : 0

        begin
          pid, = Process.waitpid2(-1, options)
          return if pid.nil? # No child exited yet

          # Find this child in our tracking array
          @process_mutex.synchronize do
            child_info = @child_processes.find { |c| c[:pid] == pid }
            if child_info
              # Read result from pipe
              begin
                data = child_info[:pipe].read
                result = YAML.safe_load(data, permitted_classes: [Symbol, Time], aliases: true)
                child_info[:pipe].close

                if result.is_a?(Hash) && result[:error]
                  @logger.error("[Minigun:#{@job_id}][#{@name}] Child process #{pid} failed: #{result[:error]}")
                  @logger.error("[Minigun:#{@job_id}][#{@name}] #{result[:backtrace].join("\n")}") if result[:backtrace]
                  @failed_count.increment(child_info[:items_count])
                else
                  runtime = Time.now - child_info[:start_time]
                  success_count = result[:success] || 0
                  failed_count = result[:failed] || 0
                  emitted_count = result[:emitted] || 0

                  @logger.info("[Minigun:#{@job_id}][#{@name}] Child process #{pid} finished in #{runtime.round(2)}s. " \
                               "Success: #{success_count}, Failed: #{failed_count}, Emitted: #{emitted_count}")

                  @processed_count.increment(success_count)
                  @failed_count.increment(failed_count)
                  @emitted_count.increment(emitted_count) if emitted_count > 0
                end
              rescue EOFError, TypeError, ArgumentError => e
                @logger.error("[Minigun:#{@job_id}][#{@name}] Error reading from child pipe: #{e.message}")
                @failed_count.increment(child_info[:items_count])
              ensure
                # Remove this child from our tracking array
                @child_processes.delete(child_info)
              end
            end
          end
        rescue Errno::ECHILD
          # No child processes
          nil
        end
      end

      def wait_for_child_processes
        # Log waiting message
        @logger.info("[Minigun:#{@job_id}][#{@name}] Waiting for #{@child_processes.size} child processes to finish...") if @child_processes.any?

        # Wait for all child processes to finish
        check_finished_processes(non_blocking: false) until @child_processes.empty?

        @logger.info("[Minigun:#{@job_id}][#{@name}] All child processes finished.")
      end
    end
  end
end
