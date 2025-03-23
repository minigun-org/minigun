# frozen_string_literal: true

module Minigun
  # The Runner class handles the execution of a Minigun job
  class Runner
    extend Forwardable
    def_delegators :@logger, :info, :warn, :error, :debug

    attr_reader :job_id, :task

    def initialize(context)
      @context = context

      # Get the task - either directly passed, from context if it's a Task, or from context's class
      @task = if context.is_a?(Minigun::Task)
                context
              elsif context.class.respond_to?(:_minigun_task)
                context.class._minigun_task
              else
                # Default to a new task
                Minigun::Task.new
              end

      @config = @task.config
      @producer_stage_block = @task.stage_blocks[:default]
      @consumer_stage_block = @task.stage_blocks[:default]

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
      @stage_process_pids = []
      @produced_count = 0
      @accumulated_count = 0
      @job_start_at = Time.now
      @job_id = SecureRandom.uuid[0..7]

      # Setup signal handling
      setup_signal_handlers
    end

    def run
      log_job_started
      @task.run_hooks(:before_run, @context)

      # Create the thread pool for producer
      producer_pool = Concurrent::FixedThreadPool.new(1)

      # Start the producer and accumulator stages
      producer_future = Concurrent::Future.execute(executor: producer_pool) { run_producer_stage }
      accumulator_future = Concurrent::Future.execute { run_accumulator_stage }

      # Wait for producer to finish
      producer_future.wait
      raise producer_future.reason if producer_future.rejected?

      # Signal end of queue and wait for accumulator
      @queue << :EOQ
      accumulator_future.wait
      raise accumulator_future.reason if accumulator_future.rejected?

      # Wait for all consumer processes to finish
      wait_all_stage_processes

      # Complete the job
      @job_end_at = Time.now
      log_job_finished
      @task.run_hooks(:after_run, @context)

      @accumulated_count
    ensure
      producer_pool&.shutdown
      producer_pool&.wait_for_termination(10)
    end

    private

    def run_producer_stage
      info("[Minigun:#{@job_id}][Stage:producer] Started producer thread")
      Thread.current[:minigun_queue] = []

      begin
        @context.instance_eval(&@producer_stage_block)
        items = Thread.current[:minigun_queue]

        info("[Minigun:#{@job_id}][Stage:producer] Enqueuing #{items.size} items...")
        items.each { |item| @queue << item }
        @produced_count += items.size
      rescue StandardError => e
        error("[Minigun:#{@job_id}][Stage:producer] Error: #{e.class}: #{e.message}\n#{e.backtrace.join("\n")}")
        raise e
      end

      @task.run_hooks(:after_producer_finished, @context)
      info("[Minigun:#{@job_id}][Stage:producer] Done. #{@produced_count} items produced")
    end

    def run_accumulator_stage
      info("[Minigun:#{@job_id}][Stage:accumulator] Started accumulator thread")
      accumulator_map = {}
      i = 0

      # Process items as they come in
      while (item = @queue.pop)
        break if item == :EOQ

        # Group items by type
        item_type = item.class.name
        accumulator_map[item_type] ||= []
        accumulator_map[item_type] << item

        i += 1
        @accumulated_count += 1

        # Periodically check if we need to fork consumers
        check_and_fork_stages(accumulator_map) if i % @accumulator_check_interval == 0
      end

      # Process any remaining items
      process_batch(accumulator_map) unless accumulator_map.empty?

      info("[Minigun:#{@job_id}][Stage:accumulator] Done. #{@accumulated_count} items accumulated")
    end

    def check_and_fork_stages(accumulator_map)
      # Fork if any queue contains more than the max threshold
      accumulator_map.each do |type, items|
        next unless items.size >= @accumulator_max_queue

        # Process this batch
        process_batch(type => items)
        accumulator_map[type] = []
      end

      # If total items exceeds max_all, process all items
      total_items = accumulator_map.values.sum(&:size)
      return unless total_items >= @accumulator_max_all

      process_batch(accumulator_map)
      accumulator_map.clear
    end

    def process_batch(items_map)
      case @fork_mode
      when :always
        if Process.respond_to?(:fork)
          fork_stage(items_map)
        else
          warn("[Minigun:#{@job_id}][Stage:fork] Fork mode set to :always but forking not supported. Using threading instead.")
          consume_items_in_current_process(items_map.values.flatten)
        end
      when :never
        # Process in the current process with threading
        consume_items_in_current_process(items_map.values.flatten)
      else
        # Default auto mode - fork if items exceed threshold and platform supports it
        if Process.respond_to?(:fork)
          fork_stage(items_map)
        else
          consume_items_in_current_process(items_map.values.flatten)
        end
      end
    end

    def fork_stage(items_map)
      wait_max_stage_processes

      total_items = items_map.values.sum(&:size)
      info("[Minigun:#{@job_id}][Stage:fork] Forking for #{total_items} items...")

      # Create a pipe for parent-child communication
      rd, wr = IO.pipe

      # Run before_fork hook
      @task.run_hooks(:before_fork, @context)

      # Fork a new process
      @pid = Process.fork do
        # Set up signal handling for the child
        trap_child_signals

        # Close parent's pipe end
        rd.close

        # Run after_fork hook
        @task.run_hooks(:after_fork, @context)

        # Set descriptive process title if available
        Process.setproctitle("minigun-#{@job_id}-stage-fork") if Process.respond_to?(:setproctitle)

        info("[Minigun:#{@job_id}][Stage:fork][PID #{@pid}] Started")

        # Process the items
        result = {}
        begin
          result = consume_items(items_map.values.flatten)
        rescue StandardError => e
          result = { error: "#{e.class}: #{e.message}" }
          error("[Minigun:#{@job_id}][Stage:fork][PID #{@pid}] Error: #{e.class}: #{e.message}\n#{e.backtrace.join("\n")}")
        ensure
          # Run after stage finished hook
          @task.run_hooks(:after_consumer_finished)
        end

        # Write results back to the parent process
        wr.write(YAML.dump(result))
        wr.close

        # Exit cleanly
        exit!(0)
      end

      # In parent process
      wr.close

      @stage_process_pids << {
        pid: @pid,
        result_reader: rd,
        items: total_items,
        start_time: Time.now
      }

      # Reset PID to indicate we're back in the parent
      @pid = nil
    end

    def consume_items_in_current_process(items)
      info("[Minigun:#{@job_id}][Stage:consume] Processing #{items.size} items in current process...")
      result = consume_items(items)
      info("[Minigun:#{@job_id}][Stage:consume] Processed #{result[:success]} items (#{result[:failed]} failed)")
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
        result = @consumer_stage_block ? @task.instance_exec(item, &@consumer_stage_block) : { success: true, result: nil }

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

    def wait_max_stage_processes
      return if @stage_process_pids.size < @max_processes

      # Check if any child has finished
      check_finished_children(non_blocking: true)

      # If still at max, wait for one to finish
      return unless @stage_process_pids.size >= @max_processes

      check_finished_children(non_blocking: false)
    end

    def check_finished_children(non_blocking: false)
      options = non_blocking ? Process::WNOHANG : 0

      # Try to reap any finished children
      begin
        pid, = Process.waitpid2(-1, options)
        return if pid.nil? # No child exited yet

        # Find this child in our tracking array
        child_info = @stage_process_pids.find { |c| c[:pid] == pid }
        if child_info
          # Read result from pipe
          begin
            data = child_info[:result_reader].read
            result = YAML.safe_load(data, permitted_classes: [Symbol, Time], aliases: true)
            if result.is_a?(Hash) && result[:error]
              error("[Minigun:#{@job_id}][Stage:fork][PID #{pid}] Failed with error: #{result[:error]}")
            else
              runtime = Time.now - child_info[:start_time]
              info("[Minigun:#{@job_id}][Stage:fork][PID #{pid}] Finished in #{runtime.round(2)}s. "\
                   "Success: #{result[:success]}, Failed: #{result[:failed]}")
            end
          rescue StandardError => e
            error("[Minigun:#{@job_id}][Stage:fork][PID #{pid}] Error reading result: #{e.message}")
          ensure
            child_info[:result_reader].close
          end

          # Remove from tracking
          @stage_process_pids.delete(child_info)
        end
      rescue Errno::ECHILD
        # No children to wait for
      end
    end

    def wait_all_stage_processes
      # First check for any already finished children
      check_finished_children(non_blocking: true)

      # Wait for any remaining processes
      return if @stage_process_pids.empty?

      info("[Minigun:#{@job_id}] Waiting for #{@stage_process_pids.size} running processes to finish...")

      @stage_process_pids.dup.each do |child_info|
        pid = child_info[:pid]

        # Wait for this child to finish
        _, status = Process.wait2(pid)

        # Collect and parse result
        begin
          result = child_info[:result_reader].read
          result = YAML.safe_load(result, permitted_classes: [Symbol, Time, DateTime, Date]) if result && !result.empty?
          runtime = Time.now - child_info[:start_time]

          if result && result[:error]
            error("[Minigun:#{@job_id}][Stage:fork][PID #{pid}] Failed with error: #{result[:error]}")
          else
            items_processed = result.is_a?(Hash) ? result[:processed] || 0 : 0
            info("[Minigun:#{@job_id}][Stage:fork][PID #{pid}] Finished in #{runtime.round(2)}s. "\
                 "Processed #{items_processed} items (exited with #{status.exitstatus})")
          end
        rescue StandardError => e
          error("[Minigun:#{@job_id}][Stage:fork][PID #{pid}] Error reading result: #{e.message}")
        end

        # Clean up resources
        child_info[:result_reader].close if child_info[:result_reader] && !child_info[:result_reader].closed?
        @stage_process_pids.delete(child_info)
      rescue Errno::ECHILD
        # Child process doesn't exist anymore
        @stage_process_pids.delete(child_info)
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
          info("[Minigun:#{@job_id}][Stage:fork][PID #{@pid}] Received #{signal} signal, exiting...")
          exit!(0)
        end
      end
    end

    def shutdown_gracefully(signal)
      info("[Minigun:#{@job_id}] Received #{signal} signal, shutting down gracefully...")

      # Send signal to all child processes
      @stage_process_pids.each do |child_info|
        Process.kill(signal, child_info[:pid])
      rescue Errno::ESRCH
        # Process already exited
      end

      # Wait a bit for children to exit
      sleep(0.5)

      # Force kill any remaining children
      @stage_process_pids.each do |child_info|
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
