# frozen_string_literal: true

require 'securerandom'
require 'concurrent'
require 'forwardable'
require 'yaml'

module Minigun
  # The Runner class handles the execution of a Minigun job
  class Runner
    extend Forwardable
    def_delegators :@logger, :info, :warn, :error, :debug

    attr_reader :job_id

    def initialize(task)
      @task = task
      @config = task.class._minigun_config
      @producer_block = task.class._minigun_processor_blocks&.[](:default)
      @consumer_block = task.class._minigun_processor_blocks&.[](:default)

      # Load configuration
      @logger = @config[:logger]
      @max_threads = @config[:max_threads]
      @max_processes = @config[:max_processes]
      @max_retries = @config[:max_retries]
      @batch_size = @config[:batch_size]
      @accumulator_max_queue = @config[:accumulator_max_queue]
      @accumulator_max_all = @config[:accumulator_max_all]
      @accumulator_check_interval = @config[:accumulator_check_interval]
      @fork_mode = @config[:fork_mode]

      # Initialize counters and structures
      @queue = Queue.new
      @consumer_pids = []
      @produced_count = 0
      @accumulated_count = 0
      @job_start_at = Time.now
      @job_id = SecureRandom.uuid[0..7]

      # Setup signal handling
      setup_signal_handlers
    end

    def run
      log_job_started
      @task.run_hooks(:before_run)

      # Create the thread pool for producer
      producer_pool = Concurrent::FixedThreadPool.new(1)

      # Start the producer and accumulator
      producer_future = Concurrent::Future.execute(executor: producer_pool) { run_producer }
      accumulator_future = Concurrent::Future.execute { run_accumulator }

      # Wait for producer to finish
      producer_future.wait
      raise producer_future.reason if producer_future.rejected?

      # Signal end of queue and wait for accumulator
      @queue << :EOQ
      accumulator_future.wait
      raise accumulator_future.reason if accumulator_future.rejected?

      # Wait for all consumer processes to finish
      wait_all_consumer_processes

      # Complete the job
      @job_end_at = Time.now
      log_job_finished
      @task.run_hooks(:after_run)

      @accumulated_count
    ensure
      producer_pool&.shutdown
      producer_pool&.wait_for_termination(10)
    end

    private

    def run_producer
      info("[Minigun:#{@job_id}][Producer] Started producer thread")
      Thread.current[:minigun_queue] = []

      begin
        @task.instance_eval(&@producer_block)
        items = Thread.current[:minigun_queue]

        info("[Minigun:#{@job_id}][Producer] Enqueuing #{items.size} items...")
        items.each { |item| @queue << item }
        @produced_count = items.size
      rescue StandardError => e
        error("[Minigun:#{@job_id}][Producer] Error in producer: #{e.class}: #{e.message}\n#{e.backtrace.join("\n")}")
        raise e
      ensure
        @task.run_hooks(:after_producer_finished)
        info("[Minigun:#{@job_id}][Producer] Done. #{@produced_count} items produced")
      end
    end

    def run_accumulator
      info("[Minigun:#{@job_id}][Accumulator] Started accumulator thread")
      accumulator_map = {}

      i = 0
      until (item = @queue.pop) == :EOQ
        item_type = item.class.name
        accumulator_map[item_type] ||= []
        accumulator_map[item_type] << item

        i += 1
        check_and_fork_consumers(accumulator_map) if i % @accumulator_check_interval == 0
      end

      # Process any remaining items
      process_batch(accumulator_map) unless accumulator_map.empty?
      @accumulated_count = i

      info("[Minigun:#{@job_id}][Accumulator] Done. #{@accumulated_count} items accumulated")
    end

    def check_and_fork_consumers(accumulator_map)
      # Fork if any queue contains more than the max threshold
      accumulator_map.each do |type, items|
        next unless items.size >= @accumulator_max_queue

        type_items = { type => items }
        process_batch(type_items)
        accumulator_map[type] = []
      end

      # Fork if all queues together contain more than the max threshold
      total_items = accumulator_map.values.sum(&:size)
      return unless total_items >= @accumulator_max_all

      process_batch(accumulator_map)
      accumulator_map.clear
    end

    def process_batch(items_map)
      case @fork_mode
      when :never
        consume_items_in_current_process(items_map.values.flatten)
      when :always
        # Only use forking if supported
        if Process.respond_to?(:fork)
          fork_consumer(items_map)
        else
          warn("[Minigun:#{@job_id}][Consumer] Fork mode set to :always but forking not supported. Using threading instead.")
          consume_items_in_current_process(items_map.values.flatten)
        end
      when :auto
        # Use forking if supported, otherwise threading
        if Process.respond_to?(:fork)
          fork_consumer(items_map)
        else
          consume_items_in_current_process(items_map.values.flatten)
        end
      end
    end

    def fork_consumer(items_map)
      wait_max_consumer_processes
      @task.run_hooks(:before_fork)

      total_items = items_map.values.sum(&:size)
      info("[Minigun:#{@job_id}][Consumer] Forking for #{total_items} items...")

      # Create a pipe for communication with the child
      read_pipe, write_pipe = IO.pipe

      pid = Process.fork do
        # In child process
        @pid = Process.pid

        # Close unused pipe end
        read_pipe.close

        # Trap signals
        trap_child_signals

        info("[Minigun:#{@job_id}][Consumer][PID #{@pid}] Started")
        @task.run_hooks(:after_fork)

        # Process items
        result = consume_items(items_map.values.flatten)

        # Send result back to parent
        write_pipe.write(Marshal.dump(result))

        # Run after consumer hook
        @task.run_hooks(:after_consumer_finished)

        # Exit cleanly
        write_pipe.close
        exit!(0)
      rescue StandardError => e
        # Handle errors in child process
        error("[Minigun:#{@job_id}][Consumer][PID #{@pid}] Error: #{e.class}: #{e.message}\n#{e.backtrace.join("\n")}")
        write_pipe.write(Marshal.dump({ error: e.message }))
        write_pipe.close
        exit!(1)
      end

      # Close unused pipe end in parent
      write_pipe.close

      return unless pid

      @consumer_pids << {
        pid: pid,
        pipe: read_pipe,
        start_time: Time.now,
        items_count: total_items
      }
    end

    def consume_items_in_current_process(items)
      info("[Minigun:#{@job_id}][Consumer] Processing #{items.size} items in current process...")
      result = consume_items(items)
      info("[Minigun:#{@job_id}][Consumer] Processed #{result[:success]} items (#{result[:failed]} failed)")
      result
    end

    def consume_items(items)
      thread_pool = Concurrent::FixedThreadPool.new(@max_threads)
      results = Concurrent::Hash.new

      results[:total] = items.size
      results[:success] = 0
      results[:failed] = 0

      # Process items in batches using the thread pool
      items.each_slice(@batch_size) do |batch|
        futures = batch.map do |item|
          Concurrent::Future.execute(executor: thread_pool) do
            process_single_item(item)
          end
        end

        # Wait for all futures to complete
        futures.each do |future|
          future.wait
          if future.fulfilled?
            results[:success] += 1 if future.value
          else
            results[:failed] += 1
            error("[Minigun:#{@job_id}][Consumer] #{future.reason.class}: #{future.reason.message}")
          end
        end
      end

      # Shut down the thread pool
      thread_pool.shutdown
      thread_pool.wait_for_termination(30)

      results
    end

    def process_single_item(item)
      attempts = 0
      max_attempts = @max_retries + 1
      result = nil

      begin
        attempts += 1
        result = @consumer_block ? @task.instance_exec(item, &@consumer_block) : { success: true, result: nil }

        # For backward compatibility with tests that expect a Concurrent::Future-like interface
        if !result.respond_to?(:wait) && result.is_a?(Hash)
          # Create a pseudo-future
          pseudo_future = result.dup
          def pseudo_future.wait
            # No-op
          end
          result = pseudo_future
        end

        info("[Minigun:#{@job_id}][Consumer] Successfully processed item")
        result
      rescue StandardError => e
        error("[Minigun:#{@job_id}][Consumer] Attempt #{attempts} failed: #{e.message}")
        if attempts < max_attempts
          sleep_with_backoff(attempts)
          retry
        else
          error("[Minigun:#{@job_id}][Consumer] Failed to process item after #{max_attempts} attempts: #{e.message}")
          error(e.backtrace.join("\n")) if e.backtrace
          { success: false, error: e }
        end
      end
    end

    def sleep_with_backoff(attempts)
      sleep(((5**attempts) / 100.0) + rand(0.05..1))
    end

    def wait_max_consumer_processes
      return if @consumer_pids.size < @max_processes

      # Check if any child has finished
      check_finished_children(non_blocking: true)

      # If still at max, wait for one to finish
      return unless @consumer_pids.size >= @max_processes

      check_finished_children(non_blocking: false)
    end

    def check_finished_children(non_blocking: false)
      options = non_blocking ? Process::WNOHANG : 0

      # Try to reap any finished children
      begin
        pid, = Process.waitpid2(-1, options)
        return if pid.nil? # No child exited yet

        # Find this child in our tracking array
        child_info = @consumer_pids.find { |c| c[:pid] == pid }
        if child_info
          # Read result from pipe
          begin
            data = child_info[:pipe].read
            result = YAML.safe_load(data, permitted_classes: [Symbol, Time], aliases: true)
            if result.is_a?(Hash) && result[:error]
              error("[Minigun:#{@job_id}][Consumer][PID #{pid}] Failed with error: #{result[:error]}")
            else
              runtime = Time.now - child_info[:start_time]
              info("[Minigun:#{@job_id}][Consumer][PID #{pid}] Finished in #{runtime.round(2)}s. "\
                   "Success: #{result[:success]}, Failed: #{result[:failed]}")
            end
          rescue StandardError => e
            error("[Minigun:#{@job_id}][Consumer][PID #{pid}] Error reading result: #{e.message}")
          ensure
            child_info[:pipe].close
          end

          # Remove from tracking
          @consumer_pids.delete(child_info)
        end
      rescue Errno::ECHILD
        # No children to wait for
      end
    end

    def wait_all_consumer_processes
      # First check for any already finished children
      check_finished_children(non_blocking: true)

      # Wait for remaining children
      @consumer_pids.dup.each do |child_info|
        pid = child_info[:pid]
        begin
          # Wait for this specific child
          Process.waitpid(pid)

          # Read result from pipe
          begin
            data = child_info[:pipe].read
            result = YAML.safe_load(data, permitted_classes: [Symbol, Time], aliases: true)
            if result.is_a?(Hash) && result[:error]
              error("[Minigun:#{@job_id}][Consumer][PID #{pid}] Failed with error: #{result[:error]}")
            else
              runtime = Time.now - child_info[:start_time]
              info("[Minigun:#{@job_id}][Consumer][PID #{pid}] Finished in #{runtime.round(2)}s. "\
                   "Success: #{result[:success]}, Failed: #{result[:failed]}")
            end
          rescue StandardError => e
            error("[Minigun:#{@job_id}][Consumer][PID #{pid}] Error reading result: #{e.message}")
          ensure
            child_info[:pipe].close
          end

          # Remove from tracking
          @consumer_pids.delete(child_info)
        rescue Errno::ECHILD
          # Child already exited
          @consumer_pids.delete(child_info)
        end
      end
    end

    def setup_signal_handlers
      # Only set up handlers if we're in the parent process
      return if @pid

      @original_handlers = {}

      # Use OS-agnostic signal handling
      signals = RUBY_PLATFORM.match?(/win32|mingw/) ? %i[INT TERM] : %i[INT TERM QUIT]

      signals.each do |signal|
        @original_handlers[signal] = Signal.trap(signal) do
          shutdown_gracefully(signal)
        end
      end
    end

    def trap_child_signals
      # Set up signal handlers for child processes
      %i[INT TERM QUIT].each do |signal|
        Signal.trap(signal) do
          info("[Minigun:#{@job_id}][Consumer][PID #{@pid}] Received #{signal} signal, exiting...")
          exit!(0)
        end
      end
    end

    def shutdown_gracefully(signal)
      info("[Minigun:#{@job_id}] Received #{signal} signal, shutting down gracefully...")

      # Send signal to all child processes
      @consumer_pids.each do |child_info|
        Process.kill(signal, child_info[:pid])
      rescue Errno::ESRCH
        # Process already exited
      end

      # Wait a bit for children to exit
      sleep(0.5)

      # Force kill any remaining children
      @consumer_pids.each do |child_info|
        Process.kill(:KILL, child_info[:pid])
      rescue Errno::ESRCH
        # Process already exited
      end

      # Restore original signal handlers and re-raise signal
      @original_handlers.each do |sig, handler|
        Signal.trap(sig, handler)
      end

      Process.kill(signal, Process.pid)
    end

    def log_job_started
      info("[Minigun:#{@job_id}] #{@task.class.name} started")
      info("[Minigun:#{@job_id}] Configuration: max_processes=#{@max_processes}, max_threads=#{@max_threads}, fork_mode=#{@fork_mode}")
    end

    def log_job_finished
      runtime = @job_end_at - @job_start_at
      rate = @accumulated_count / [runtime / 60.0, 0.01].max # Avoid division by zero

      info("[Minigun:#{@job_id}] #{@task.class.name} finished")
      info("[Minigun:#{@job_id}] Statistics: items=#{@accumulated_count}, runtime=#{runtime.round(2)}s, rate=#{rate.round(2)} items/minute")
    end
  end
end
