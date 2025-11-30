# frozen_string_literal: true

require_relative 'worker_monitor'

module Minigun
  # Execution strategies for running pipeline stages
  module Execution
    # Base executor class - all execution strategies inherit from this
    # NOTE: Stages now manage their own execution loops internally via execute(context, input_queue, output_queue).
    # Executors define HOW that execution happens (inline, threaded, etc).
    class Executor
      attr_reader :stage_ctx

      def initialize(stage_ctx)
        @stage_ctx = stage_ctx
      end

      # Execute the actual stage logic using this executor's strategy
      # Subclasses implement this to control HOW execution happens
      # @param stage [Stage] The stage to execute
      # @param user_context [Object] User context for instance_exec
      # @param input_queue [Queue] Input queue for items
      # @param output_queue [Queue] Output queue for results
      def execute_stage(_stage, _user_context, _input_queue, _output_queue)
        raise NotImplementedError.new("#{self.class}#execute_stage must be implemented")
      end

      # Shutdown and cleanup resources
      def shutdown
        # Default: no-op
      end
    end

    # Inline execution - no concurrency, executes immediately in current thread
    class InlineExecutor < Executor
      def execute_stage(stage, user_context, input_queue, output_queue)
        stage.execute(user_context, input_queue, output_queue, @stage_ctx.stage_stats)
      end
    end

    # Thread pool executor - manages concurrent execution with threads
    class ThreadPoolExecutor < Executor
      attr_reader :max_size

      def initialize(stage_ctx, max_size: nil, pool_timeout: nil) # rubocop:disable Lint/UnusedMethodArgument
        super(stage_ctx)
        @max_size = max_size || 5
        @active_threads = []
        @mutex = Mutex.new
      end

      def execute_stage(stage, user_context, input_queue, output_queue)
        wait_for_slot

        thread = Thread.new do
          stage.execute(user_context, input_queue, output_queue, @stage_ctx.stage_stats)
        ensure
          @mutex.synchronize { @active_threads.delete(Thread.current) }
        end

        @mutex.synchronize { @active_threads << thread }
        thread.value # Wait for completion
      end

      def shutdown
        @mutex.synchronize { @active_threads.dup }.each do |thread|
          thread.kill if thread.alive?
        end
        @active_threads.clear
      end

      private

      def wait_for_slot
        loop do
          return if @mutex.synchronize { @active_threads.size } < @max_size

          sleep 0.01
        end
      end
    end

    # Abstract base class for fork-based executors
    # Handles common IPC result communication logic
    class AbstractForkExecutor < Executor
      attr_reader :max_size

      def initialize(stage_ctx, max_size: nil, pool_timeout: nil) # rubocop:disable Lint/UnusedMethodArgument
        super(stage_ctx)
        @max_size = max_size || 5
        @mutex = Mutex.new
      end

      protected

      # Write result from child to parent via IPC pipe
      def write_result_to_pipe(result, writer)
        if result.nil?
          Marshal.dump({ type: :no_result }, writer)
        else
          Marshal.dump({ type: :result, result: result }, writer)
        end
        writer.flush
      end

      # Read result from child via IPC pipe
      def read_result_from_pipe(reader, output_queue, stage_ctx = nil)
        response = Marshal.load(reader) # rubocop:disable Security/MarshalLoad
        case response[:type]
        when :result
          result = response[:result]
          # Handle arrays of results (multiple items written to output_queue)
          if result.is_a?(Array)
            result.each { |item| output_queue << item }
          elsif !result.nil?
            output_queue << result
          end
        when :routed_result
          # Handle explicitly routed result from IPC worker
          handle_routed_result(response, stage_ctx, output_queue)
        when :error
          error_msg = response[:error] || 'Unknown error in forked process'
          backtrace = response[:backtrace]
          exception = RuntimeError.new("COW forked process failed: #{error_msg}")
          exception.set_backtrace(backtrace) if backtrace
          raise exception
        when :serialization_error
          # Result couldn't be serialized (contains IO, Proc, etc.)
          # Log warning but continue - item is skipped
          Minigun.logger.warn "[Minigun] Skipped non-serializable result: #{response[:error]} (type: #{response[:item_type]})"
        when :no_result
          # Child processed but produced no output
        when :end_of_stage
          # Worker finished processing and sent EndOfStage
          # Create a new EndOfStage for this IPC stage and propagate it
          if stage_ctx
            output_queue.push(Minigun::EndOfStage.new(stage_ctx.stage))
          end
        end
      rescue EOFError
        # Normal EOF - worker finished processing, re-raise to exit collection loop
        raise
      rescue IOError => e
        Minigun.logger.warn "[Minigun] Error reading from pipe: #{e.message}"
        raise
      end

      # Send error from child to parent via IPC pipe
      def write_error_to_pipe(error, writer)
        Marshal.dump(
          {
            type: :error,
            error: error.message,
            backtrace: error.backtrace
          },
          writer
        )
        writer.flush
      end

      # Handle routed result from IPC worker - routes to target stage or falls back to output_queue
      def handle_routed_result(response, stage_ctx, output_queue)
        target = response[:target]
        result = response[:result]

        unless stage_ctx && target
          output_queue << result
          return
        end

        task = stage_ctx.stage.task
        target_stage = task.stage_registry.find(target, from_pipeline: stage_ctx.stage.pipeline)
        unless target_stage
          Minigun.logger.warn "[Minigun] Target stage not found for routed result: #{target}"
          output_queue << result
          return
        end

        target_queue = task.find_queue(target_stage)
        unless target_queue
          Minigun.logger.warn "[Minigun] Target queue not found for routed result: #{target}"
          output_queue << result
          return
        end

        target_queue << result
        # Track runtime edge for END signal handling
        runtime_edges = stage_ctx.runtime_edges
        runtime_edges[stage_ctx.stage] ||= Set.new
        runtime_edges[stage_ctx.stage].add(target_stage)
      end
    end

    # COW Fork Pool Executor - Copy-On-Write fork pattern
    # Maintains a pool of up to max_size concurrent forked processes.
    # Each forked process handles ONE item then exits.
    # Memory pages are shared between parent and child until modified (COW).
    # Input item is COW-shared, but results are sent via IPC pipes.
    class CowForkPoolExecutor < AbstractForkExecutor
      def initialize(stage_ctx, max_size:, pool_timeout: nil)
        super
        @active_forks = {} # pid => fork_info
      end

      def execute_stage(stage, user_context, input_queue, output_queue)
        unless Minigun::Platform.fork?
          Minigun.logger.warn '[Minigun] Process forking not available, falling back to inline'
          return stage.execute(user_context, input_queue, output_queue, @stage_ctx.stage_stats)
        end

        # Execute before_fork hooks in parent process (once, before any forks)
        # This executes both pipeline-level and stage-specific hooks
        @stage_ctx.root_pipeline&.send(:execute_fork_hooks, :before_fork, stage.name)

        all_items_queued = false

        # Main loop: fork a process for each item as it arrives
        loop do
          # Reap any completed child processes (non-blocking)
          reap_completed_forks

          # If we have capacity and items remaining, fork for next item
          if !all_items_queued && current_active_count < @max_size
            item = input_queue.pop

            if item.is_a?(Minigun::EndOfStage)
              all_items_queued = true
            else
              # Fork a process for this single item (COW-shared)
              fork_for_item(item, stage, user_context, output_queue)
            end
          end

          # Break when all items processed and no active forks
          break if all_items_queued && current_active_count == 0

          # Small sleep to avoid busy waiting
          sleep 0.001 if current_active_count > 0
        end
      end

      def shutdown
        @mutex.synchronize { @active_forks.keys.dup }.each do |pid|
          Process.kill('TERM', pid)
        rescue StandardError
          nil
        end
        @active_forks.clear
      end

      private

      def current_active_count
        @mutex.synchronize { @active_forks.size }
      end

      def fork_for_item(item, stage, user_context, output_queue)
        # Create pipe for IPC communication (results only - item is COW-shared)
        reader, writer = IO.pipe

        stage_stats = @stage_ctx.stage_stats
        pipeline = @stage_ctx.root_pipeline

        # Fork child process - item is COW-shared (read-only, no copy until modified)
        pid = fork do
          reader.close # Close read end in child

          begin
            # Execute after_fork hooks in child process
            # This executes both pipeline-level and stage-specific hooks
            pipeline&.send(:execute_fork_hooks, :after_fork, stage.name)

            # Child process has inherited item via COW
            # Execute the stage's block on this single item
            # Use IPC-backed output queue for routing support
            capture_output = Minigun::IpcOutputQueue.new(writer, stage_stats)

            # Execute stage block with item and capture output queue
            start_time = Time.now if stage_stats
            if stage.respond_to?(:block) && stage.block
              user_context.instance_exec(item, capture_output, &stage.block)
            elsif stage.respond_to?(:call)
              stage.call_with_arity(item, capture_output, &capture_output.to_proc)
            end
            stage_stats&.record_latency(Time.now - start_time)

            # Results already sent via IpcOutputQueue during execution
            # Just close the pipe to signal completion
          rescue StandardError => e
            # Send error back to parent via IPC
            write_error_to_pipe(e, writer)
            Minigun.logger.error "[Minigun] Error in COW forked process: #{e.message}"
            Minigun.logger.debug e.backtrace.join("\n")
          ensure
            writer.close
            exit! 0
          end
        end

        unless pid
          reader.close
          writer.close
          Minigun.logger.warn '[Minigun] Failed to fork process, falling back to inline'
          # Fall back to processing inline for this item
          capture_queue = Queue.new
          capture_output = Minigun::OutputQueue.new(
            stage,
            [capture_queue],
            {},
            stage_stats: stage_stats
          )
          if stage.respond_to?(:block) && stage.block
            user_context.instance_exec(item, capture_output, &stage.block)
          elsif stage.respond_to?(:call)
            stage.call_with_arity(item, capture_output, &capture_output.to_proc)
          end
          # Write captured results to output_queue
          loop do
            result = capture_queue.pop(true) # non_block = true
            output_queue << result
          rescue ThreadError
            break
          end
          return
        end

        writer.close # Close write end in parent

        @mutex.synchronize { @active_forks[pid] = { reader: reader, output_queue: output_queue } }
      end

      def reap_completed_forks
        @mutex.synchronize do
          @active_forks.each_key do |pid|
            status = Process.wait2(pid, Process::WNOHANG)
            next unless status

            _pid, process_status = status
            fork_info = @active_forks.delete(pid)
            reader = fork_info[:reader]
            output_queue = fork_info[:output_queue]

            begin
              if process_status.success?
                # Read all results from child via IPC pipe (may be multiple with routing)
                loop do
                  read_result_from_pipe(reader, output_queue, @stage_ctx)
                end
              else
                Minigun.logger.warn "[Minigun] COW forked process #{pid} failed with status: #{process_status.exitstatus}"
              end
            rescue EOFError, IOError
              # Normal - child closed pipe after sending results
            ensure
              begin
                reader.close
              rescue StandardError
                nil
              end
            end
          end
        end
      end
    end

    # IPC Fork Pool Executor - Inter-Process Communication fork pattern
    # Creates persistent worker processes that communicate via IPC pipes.
    # Workers continuously pull items, process them, and send results back.
    # Data is serialized through pipes for both input and output, providing strong process isolation.
    #
    # Options:
    #   max_size: Number of worker processes to spawn (default: 5)
    #   pool_timeout: Overall timeout for stage execution (default: nil)
    #   restart_policy: Worker restart policy on failure (default: :never)
    #     - :never: Don't restart failed workers (default, current behavior)
    #     - :transient: Restart workers that exit abnormally (non-zero exit or signal)
    #     - :permanent: Always restart workers that exit for any reason
    #   max_restarts: Maximum restarts per worker before giving up (default: 3)
    #   restart_window: Time window in seconds for counting restarts (default: 60)
    class IpcForkPoolExecutor < AbstractForkExecutor
      def initialize(stage_ctx, max_size:, pool_timeout: nil,
                     restart_policy: :never, max_restarts: 3, restart_window: 60)
        super(stage_ctx, max_size: max_size, pool_timeout: pool_timeout)
        @workers = []
        @my_pipes = [] # Track this executor's pipes for cleanup/unregister
        @worker_monitor = WorkerMonitor.new(
          restart_policy: restart_policy,
          max_restarts: max_restarts,
          restart_window: restart_window
        )
      end

      def execute_stage(stage, user_context, input_queue, output_queue)
        unless Minigun::Platform.fork?
          Minigun.logger.warn '[Minigun] Process forking not available, falling back to inline'
          return stage.execute(user_context, input_queue, output_queue, @stage_ctx.stage_stats)
        end

        # Execute before_fork hooks in parent process (before spawning workers)
        # This executes both pipeline-level and stage-specific hooks
        @stage_ctx.root_pipeline&.send(:execute_fork_hooks, :before_fork, stage.name)

        # Spawn persistent worker processes
        spawn_workers(stage, user_context)

        # Distribute items to workers
        begin
          distribute_work(input_queue, output_queue)
        ensure
          shutdown
        end
      end

      def shutdown
        @mutex.synchronize do
          @worker_monitor.request_shutdown
          send_shutdown_signals
          sleep 0.1 # Give workers a moment to finish processing
          cleanup_workers
          @workers.clear

          # Unregister pipes from task tracking
          task = @stage_ctx.stage.task
          task.unregister_ipc_pipes(@my_pipes)
          @my_pipes.clear
        end
      end

      private

      def send_shutdown_signals
        @workers.each do |worker|
          Marshal.dump({ type: :end_of_stage }, worker[:to_worker])
          worker[:to_worker].flush
        rescue IOError, EOFError, Errno::EPIPE
          # Worker already closed or pipe broken, ignore
        end
      end

      def cleanup_workers
        @workers.each do |worker|
          cleanup_worker(worker)
        rescue StandardError
          force_kill_worker(worker[:pid])
        end
      end

      def cleanup_worker(worker)
        safe_close(worker[:to_worker])
        safe_close(worker[:from_worker])
        Process.wait2(worker[:pid], Process::WNOHANG)
      rescue Errno::ECHILD
        # Already reaped
      end

      def force_kill_worker(pid)
        Process.kill('TERM', pid)
      rescue StandardError
        nil
      end

      def spawn_workers(stage, user_context)
        @max_size.times { |i| spawn_single_worker(stage, user_context, worker_index: i) }
      end

      def spawn_single_worker(stage, user_context, worker_index: nil)
        stage_stats = @stage_ctx.stage_stats
        pipeline = @stage_ctx.root_pipeline

        # Create bidirectional pipes for IPC
        parent_read, child_write = IO.pipe
        child_read, parent_write = IO.pipe

        # Register pipes with task to track across all IPC stages
        task = stage.task
        pipes = [parent_read, child_write, child_read, parent_write]
        task.register_ipc_pipes(pipes)
        @my_pipes.concat(pipes)

        pid = fork do
          parent_read.close
          parent_write.close
          task.close_all_ipc_pipes_except([child_read, child_write])
          worker_loop(stage, user_context, stage_stats, child_read, child_write, pipeline)
        end

        unless pid
          Minigun.logger.warn '[Minigun] Failed to fork worker process'
          close_all_pipes(parent_read, parent_write, child_read, child_write)
          return
        end

        # Parent process - close child ends
        child_read.close
        child_write.close

        worker_info = {
          pid: pid,
          to_worker: parent_write,
          from_worker: parent_read,
          index: worker_index,
          stage: stage,
          user_context: user_context
        }
        @workers << worker_info
        worker_info
      end

      def close_all_pipes(*pipes)
        pipes.each { |p| safe_close(p) }
      end

      # Safely close an IO object, ignoring errors
      def safe_close(io)
        io&.close
      rescue IOError, Errno::EPIPE, Errno::EBADF
        nil
      end

      # Respawn a dead worker, returning the new worker info
      def respawn_worker(dead_worker, result_threads, output_queue)
        worker_index = dead_worker[:index]

        unless @worker_monitor.restart_allowed?(worker_index)
          Minigun.logger.error "[Minigun] Worker #{worker_index} exceeded max restarts " \
                               "(#{@worker_monitor.max_restarts} in #{@worker_monitor.restart_window}s), not restarting"
          return nil
        end

        @worker_monitor.record_restart(worker_index)
        Minigun.logger.info "[Minigun] Respawning worker #{worker_index} (policy: #{@worker_monitor.restart_policy})"

        # Clean up old worker pipes
        safe_close(dead_worker[:to_worker])
        safe_close(dead_worker[:from_worker])

        # Remove dead worker from list
        @mutex.synchronize { @workers.delete(dead_worker) }

        # Spawn replacement worker
        new_worker = spawn_single_worker(
          dead_worker[:stage],
          dead_worker[:user_context],
          worker_index: worker_index
        )

        return nil unless new_worker

        # Start a new result collection thread for the new worker
        new_thread = Thread.new(new_worker, output_queue) do |worker, out_q|
          loop do
            read_result_from_pipe(worker[:from_worker], out_q, @stage_ctx)
          end
        rescue EOFError, IOError
          # Worker closed pipe, done
        end

        result_threads << new_thread
        new_worker
      end

      # Monitor workers for crashes and respawn if needed
      def start_worker_monitor_thread(result_threads, output_queue)
        return nil unless @worker_monitor.enabled?

        Thread.new do
          loop do
            break if @worker_monitor.shutdown_requested?

            # Check for dead workers and respawn if needed
            check_and_respawn_workers(result_threads, output_queue)

            # Poll every 100ms - simple and reliable
            # Process deaths are detected via Process.wait2(WNOHANG), not pipe state
            sleep 0.1
          end
        end
      end

      def check_and_respawn_workers(result_threads, output_queue)
        workers_to_respawn = []

        @mutex.synchronize do
          @workers.each do |worker|
            # Non-blocking check if worker process has exited
            status = Process.wait2(worker[:pid], Process::WNOHANG)
            next unless status

            _pid, process_status = status

            if @worker_monitor.should_restart?(process_status)
              Minigun.logger.warn "[Minigun] Worker #{worker[:index]} (pid #{worker[:pid]}) exited: " \
                                  "#{@worker_monitor.format_exit_status(process_status)}"
              workers_to_respawn << worker
            else
              Minigun.logger.debug "[Minigun] Worker #{worker[:index]} exited normally"
            end
          rescue Errno::ECHILD
            # Process already reaped
          end
        end

        # Respawn outside the iteration to avoid modifying @workers while iterating
        workers_to_respawn.each do |worker|
          respawn_worker(worker, result_threads, output_queue)
        end
      end

      def worker_loop(stage, user_context, stage_stats, from_parent, to_parent, pipeline)
        # Execute after_fork hooks in child process
        # This executes both pipeline-level and stage-specific hooks
        pipeline&.send(:execute_fork_hooks, :after_fork, stage.name)

        # Create IPC-backed input queue that reads from parent via IPC
        ipc_input_queue = Minigun::IpcInputQueue.new(from_parent, stage)

        # Create IPC-backed output queue that writes results back to parent via IPC
        ipc_output_queue = Minigun::IpcOutputQueue.new(to_parent, stage_stats)

        begin
          # Run the stage's execute method with IPC-backed queues
          # This runs the full streaming loop in the worker process
          stage.execute(user_context, ipc_input_queue, ipc_output_queue, stage_stats)
        rescue StandardError => e
          # Send error back to parent via IPC pipe
          write_error_to_pipe(e, to_parent)
        end
      rescue EOFError, IOError
        # Parent closed pipe, exit gracefully
      ensure
        # Close pipes - EOF will naturally signal parent that worker is done
        begin
          from_parent.close
        rescue StandardError
          nil
        end

        begin
          to_parent.close
        rescue StandardError
          nil
        end

        exit! 0
      end

      def distribute_work(input_queue, output_queue)
        worker_index = 0
        received_end_of_stage = nil

        # Get nested stages' queues for dynamic routing support
        nested_queues = nested_stage_queues

        # Start result collection threads for each worker
        result_threads = @workers.map do |worker|
          Thread.new(worker, output_queue) do |w, out_q|
            loop do
              read_result_from_pipe(w[:from_worker], out_q, @stage_ctx)
            end
          rescue EOFError, IOError
            # Worker closed pipe, done
          end
        end

        # Start worker monitor thread for respawning crashed workers
        monitor_thread = start_worker_monitor_thread(result_threads, output_queue)

        # Start threads to monitor nested stages' queues and forward to workers
        nested_queue_threads = start_nested_queue_monitors(nested_queues)

        # Distribute items to workers round-robin
        begin
          loop do
            item = input_queue.pop

            if item.is_a?(Minigun::EndOfStage)
              received_end_of_stage = item
              # Send EndOfStage to all workers
              @workers.each do |worker|
                Marshal.dump({ type: :end_of_stage }, worker[:to_worker])
                worker[:to_worker].flush
              rescue IOError, EOFError, Errno::EPIPE
                # Worker already closed, ignore
              end
              break
            end

            # Round-robin distribution to workers
            worker = @workers[worker_index % @workers.size]
            worker_index += 1

            # Send item to worker via IPC
            begin
              Marshal.dump({ type: :item, item: item }, worker[:to_worker])
              worker[:to_worker].flush
            rescue TypeError, ArgumentError => e
              # Item contains non-serializable objects - skip it
              Minigun.logger.warn "[Minigun] Cannot serialize item for IPC worker: #{e.message}. Item type: #{item.class}. Skipping."
            rescue IOError, EOFError, Errno::EPIPE => e
              # Worker died - if restart policy is enabled, try to redistribute
              # Give monitor thread a chance to respawn, then retry with next worker
              if @worker_monitor.enabled?
                Minigun.logger.debug "[Minigun] Worker #{worker[:pid]} unavailable, waiting for respawn..."
                sleep 0.15 # Give monitor thread time to detect and respawn
                # Retry with a different worker
                retry_worker = @workers[(worker_index + 1) % @workers.size]
                if retry_worker && retry_worker != worker
                  begin
                    Marshal.dump({ type: :item, item: item }, retry_worker[:to_worker])
                    retry_worker[:to_worker].flush
                  rescue IOError, EOFError, Errno::EPIPE
                    Minigun.logger.warn '[Minigun] Failed to redistribute item after worker death'
                  end
                end
              else
                Minigun.logger.warn "[Minigun] Lost connection to worker #{worker[:pid]}: #{e.message}"
              end
            end
          end
        ensure
          # Stop worker monitor thread
          monitor_thread&.kill
          # Stop nested queue monitor threads
          nested_queue_threads&.each(&:kill)
          # Wait for all result collection threads to finish
          result_threads.each(&:join)
        end
      end

      # Get queues for nested stages (for dynamic routing support)
      def nested_stage_queues
        return [] unless @stage_ctx.respond_to?(:stage)

        stage = @stage_ctx.stage
        return [] unless stage.is_a?(Minigun::PipelineStage)

        nested_pipeline = stage.nested_pipeline
        return [] unless nested_pipeline

        task = stage.respond_to?(:task) ? stage.task : nil
        return [] unless task

        # Get all nested stages and their queues
        nested_pipeline.instance_variable_get(:@stages).filter_map do |nested_stage|
          queue = task.find_queue(nested_stage)
          { stage: nested_stage, queue: queue } if queue
        end
      rescue StandardError => e
        # If anything goes wrong, just skip nested queue monitoring
        Minigun.logger.debug "[IPC] Could not get nested stage queues: #{e.message}"
        []
      end

      # Start threads to monitor nested stages' queues
      def start_nested_queue_monitors(nested_queues)
        return [] if nested_queues.empty?

        worker_index_ref = { value: 0 } # Use ref to share across threads
        nested_queues.map do |nested_info|
          Thread.new do
            loop do
              # Non-blocking check for items in nested queue
              item = nested_info[:queue].pop(true) # non_block = true

              # Send item to worker with routing metadata
              worker_idx = worker_index_ref[:value]
              worker_index_ref[:value] = (worker_idx + 1) % @workers.size
              worker = @workers[worker_idx]

              Marshal.dump(
                {
                  type: :routed_item,
                  target_stage: nested_info[:stage].name,
                  item: item
                },
                worker[:to_worker]
              )
              worker[:to_worker].flush
            rescue ThreadError
              # Queue empty, sleep briefly
              sleep 0.01
            rescue StandardError => e
              # Log but don't crash the monitor thread
              Minigun.logger.debug "[IPC] Nested queue monitor error: #{e.message}"
              sleep 0.1
            end
          end
        end
      end
    end

    # Fiber pool executor - uses async gem for cooperative concurrency
    # Best for I/O-bound workloads (HTTP requests, database queries, file I/O)
    # Fibers are lightweight (~4KB) and yield automatically on blocking I/O
    #
    # Options:
    #   max_size: Maximum concurrent fibers (default: 5)
    #   pool_timeout: Maximum seconds to wait for all fibers to complete (default: nil = no timeout)
    class FiberPoolExecutor < Executor
      attr_reader :max_size, :pool_timeout

      def initialize(stage_ctx, max_size: nil, pool_timeout: nil)
        super(stage_ctx)
        @max_size = max_size || 5
        @pool_timeout = pool_timeout

        return if Minigun::Platform.fibers?

        raise Minigun::Error.new("Fiber execution requires the 'async' gem. Add `gem 'async'` to your Gemfile.")
      end

      def execute_stage(stage, user_context, input_queue, output_queue)
        # Run within Sync reactor (blocks until all fibers complete)
        Sync do |task|
          semaphore = Async::Semaphore.new(@max_size)
          barrier = Async::Barrier.new(parent: semaphore)

          # Process items concurrently with semaphore limiting
          loop do
            item = input_queue.pop
            break if item.is_a?(Minigun::EndOfStage)

            # Spawn fiber for each item (semaphore limits concurrency)
            barrier.async do
              process_item(stage, user_context, item, output_queue)
            end
          end

          # Wait for all fibers to complete (with optional timeout)
          if @pool_timeout
            task.with_timeout(@pool_timeout) do
              barrier.wait
            end
          else
            barrier.wait
          end
        rescue Async::TimeoutError
          Minigun.logger.error "[Stage:#{@stage_ctx.stage.name}] Fiber pool timeout after #{@pool_timeout}s"
          barrier.stop # Cancel remaining fibers
        end
      end

      def shutdown
        # Fibers are automatically cleaned up when Sync block exits
      end

      private

      def process_item(stage, user_context, item, output_queue)
        start_time = Time.now if @stage_ctx.stage_stats

        if stage.respond_to?(:block) && stage.block
          user_context.instance_exec(item, output_queue, &stage.block)
        elsif stage.respond_to?(:call)
          stage.call_with_arity(item, output_queue, &output_queue.to_proc)
        end

        @stage_ctx.stage_stats&.record_latency(Time.now - start_time)
      rescue StandardError => e
        Minigun.logger.error "[Stage:#{@stage_ctx.stage.name}] Fiber error: #{e.message}"
        Minigun.logger.debug e.backtrace.join("\n") if Minigun.logger.debug?
      end
    end

    # Ractor pool executor - provides true parallelism using Ruby 4.0+ Ractor::Port API
    # Each worker Ractor processes items from the main Ractor and sends results back.
    #
    # Architecture:
    # - Main Ractor creates result_port (main can receive from it)
    # - Workers receive work items via their default_port (Ractor.receive)
    # - Workers send results to result_port
    # - Main collects from result_port
    #
    # Constraints:
    # - Stage blocks must be shareable (use Ractor.shareable_proc) or items are deep-copied
    # - Input/output items must be shareable or will be copied
    # - User context cannot be shared (Ractor stages operate as pure functions)
    #
    # Falls back to ThreadPoolExecutor if:
    # - Ractor::Port not available (Ruby < 4.0)
    # - Stage block cannot be made shareable
    #
    class RactorPoolExecutor < Executor
      attr_reader :max_size

      def initialize(stage_ctx, max_size: nil, pool_timeout: nil)
        super(stage_ctx)
        @max_size = max_size || 5
        @pool_timeout = pool_timeout
        @workers = []
        @result_port = nil
        @collector_thread = nil

        # Create thread fallback for non-Ractor environments
        @fallback = nil
        return if Minigun::Platform.ractors?

        @fallback = ThreadPoolExecutor.new(stage_ctx, max_size: max_size, pool_timeout: pool_timeout)
      end

      def execute_stage(stage, user_context, input_queue, output_queue)
        if @fallback
          Minigun.logger.warn '[Minigun] Ractors not available (requires Ruby 4.0+), falling back to thread pool'
          return @fallback.execute_stage(stage, user_context, input_queue, output_queue)
        end

        # Create result port - main Ractor can receive from this
        @result_port = Ractor::Port.new

        # Create shareable proc from stage block if possible
        stage_proc = create_shareable_proc(stage)
        unless stage_proc
          Minigun.logger.warn '[Minigun] Stage block is not Ractor-shareable, falling back to threads'
          @fallback = ThreadPoolExecutor.new(@stage_ctx, max_size: @max_size, pool_timeout: @pool_timeout)
          return @fallback.execute_stage(stage, user_context, input_queue, output_queue)
        end

        # Spawn worker Ractors
        spawn_workers(stage_proc)

        # Distribute work and collect results
        begin
          distribute_work(input_queue, output_queue)
        ensure
          shutdown
        end
      end

      def shutdown
        # Send shutdown signal to all workers first (parallel)
        # rubocop:disable Style/CombinableLoops -- intentionally separate: signal all, then join all
        @workers.each do |worker|
          worker.send(:shutdown)
        rescue Ractor::ClosedError
          # Already closed, will handle in join phase
        end

        # Then wait for all workers to finish (parallel join)
        @workers.each do |worker|
          worker.join
        rescue Ractor::RemoteError => e
          Minigun.logger.warn "[Ractor] Worker error during shutdown: #{e.cause&.message || e.message}"
        end
        # rubocop:enable Style/CombinableLoops

        @workers.clear

        # Close the result port
        @result_port&.close
        @result_port = nil
      end

      private

      def create_shareable_proc(stage)
        return nil unless stage.respond_to?(:block) && stage.block

        block = stage.block

        # Check if the block is already shareable (e.g., created with shareable: true option)
        return block if Ractor.shareable?(block)

        # Try to make the proc shareable
        # Note: User's block must not capture non-shareable state
        begin
          Ractor.make_shareable(block.dup)
        rescue Ractor::IsolationError => e
          Minigun.logger.debug "[Ractor] Block not shareable: #{e.message}"
          # Fall back to threads for non-shareable blocks
          nil
        end
      end

      def spawn_workers(stage_proc)
        result_port = @result_port

        @max_size.times do |i|
          worker = Ractor.new(stage_proc, result_port, name: "minigun-ractor-#{i}") do |proc, rport|
            # Output collector that responds to << for DSL compatibility
            # Defined inline in the Ractor block since external classes can't be passed
            output_collector = Class.new do
              attr_reader :results

              def initialize
                @results = []
              end

              def <<(item)
                @results << item
                self
              end

              def push(item, target: nil) # rubocop:disable Lint/UnusedMethodArgument
                # Routing not supported in Ractor mode - just collect
                @results << item
              end
            end

            loop do
              msg = Ractor.receive # Receive from default port
              break if msg == :shutdown

              begin
                start_time = Time.now
                item = msg[:item]
                # Process item with the shareable proc
                # Use an output collector object that responds to <<
                collector = output_collector.new
                proc.call(item, collector)
                latency = Time.now - start_time

                # Send each result back to main via result_port
                collector.results.each { |r| rport << { type: :result, result: r } }

                # Signal item completion with latency for stats tracking
                rport << { type: :item_done, latency: latency }
              rescue StandardError => e
                rport << { type: :error, error: e.message, backtrace: e.backtrace }
                rport << { type: :item_done }
              end
            end
          end
          @workers << worker
        end
      end

      def distribute_work(input_queue, output_queue)
        worker_index = 0
        pending_count = 0
        all_sent = false
        mutex = Mutex.new
        done_cv = ConditionVariable.new

        # Thread to collect results from result_port
        @collector_thread = Thread.new do
          loop do
            begin
              msg = @result_port.receive
            rescue Ractor::ClosedError
              break
            end

            case msg[:type]
            when :result
              output_queue << msg[:result]
            when :error
              Minigun.logger.error "[Ractor] Worker error: #{msg[:error]}"
              Minigun.logger.debug msg[:backtrace]&.join("\n") if Minigun.logger.debug?
            when :item_done
              # Record latency if available
              @stage_ctx.stage_stats&.record_latency(msg[:latency]) if msg[:latency]
              mutex.synchronize do
                pending_count -= 1
                done_cv.signal if pending_count <= 0 && all_sent
              end
            when :collector_done
              break
            end
          end
        end

        # Distribute items round-robin to workers
        loop do
          item = input_queue.pop

          if item.is_a?(Minigun::EndOfStage)
            mutex.synchronize { all_sent = true }
            break
          end

          mutex.synchronize { pending_count += 1 }
          @workers[worker_index % @max_size].send({ item: item })
          worker_index += 1
        end

        # Wait for all pending items to complete
        mutex.synchronize do
          done_cv.wait(mutex) until pending_count <= 0
        end

        # Signal collector to stop and wait
        @result_port << { type: :collector_done }
        @collector_thread&.join
        @collector_thread = nil
      end
    end

    # Cluster pool executor - distributes work across remote machines using DRb
    # This is similar to IpcForkPoolExecutor but works across network boundaries
    #
    # Two modes:
    # 1. Coordinator mode (coordinator_uri): Workers connect to coordinator which distributes work
    # 2. Direct mode (worker_uris): Connect directly to workers, round-robin distribution
    #
    # Delivery modes:
    #   :at_most_once (default): Items may be lost on worker failure, but never duplicated
    #   :at_least_once: Items are redelivered on worker failure; duplicates possible
    #
    # Options:
    #   coordinator_uri: DRb URI of the coordinator (e.g., "druby://10.0.0.1:9000")
    #   worker_uris: Array of worker URIs for direct mode (no coordinator)
    #   min_workers: Minimum workers required before starting (default: 1, coordinator mode only)
    #   worker_timeout: Seconds to wait for workers to connect (default: 30)
    #   pool_timeout: Overall timeout for stage execution (default: nil)
    #   delivery_mode: :at_most_once or :at_least_once (default: :at_most_once)
    #   max_retries: Maximum retry attempts per item in at_least_once mode (default: 3)
    #
    # Note: The stage block is NOT sent to workers - workers must have the same
    # codebase deployed and register the stage processor locally.
    class ClusterPoolExecutor < Executor
      attr_reader :coordinator_uri, :worker_uris, :min_workers, :delivery_mode

      def initialize(stage_ctx, coordinator_uri: nil, worker_uris: nil, min_workers: 1,
                     worker_timeout: 30, pool_timeout: nil, shutdown_on_done: false, # rubocop:disable Lint/UnusedMethodArgument
                     delivery_mode: :at_most_once, max_retries: 3)
        super(stage_ctx)
        @coordinator_uri = coordinator_uri
        @worker_uris = worker_uris
        @min_workers = min_workers
        @worker_timeout = worker_timeout
        @shutdown_on_done = shutdown_on_done
        @delivery_mode = delivery_mode
        @max_retries = max_retries
        @coordinator = nil
        @owns_coordinator = false
        @direct_workers = [] # For direct mode
        @direct_mode = worker_uris && !worker_uris.empty?
      end

      def execute_stage(stage, _user_context, input_queue, output_queue)
        if @direct_mode
          execute_direct_mode(stage, input_queue, output_queue)
        else
          execute_coordinator_mode(stage, input_queue, output_queue)
        end
      end

      def shutdown
        if @direct_mode
          shutdown_direct_mode
        else
          shutdown_coordinator_mode
        end
      end

      private

      # === Coordinator Mode ===

      def execute_coordinator_mode(stage, input_queue, output_queue)
        setup_coordinator(stage.name)

        unless @coordinator.wait_for_workers(min_count: @min_workers, timeout: @worker_timeout)
          raise Cluster::Error.new("Timeout waiting for workers. Got #{@coordinator.worker_count}, need #{@min_workers}")
        end

        Minigun.logger.info "[Cluster] Starting stage :#{stage.name} with #{@coordinator.worker_count} workers"

        begin
          distribute_and_collect_coordinator(stage, input_queue, output_queue)
        ensure
          shutdown_coordinator_mode
        end
      end

      def shutdown_coordinator_mode
        return unless @coordinator

        @coordinator.enqueue_end_of_stage
        sleep 0.1

        @coordinator.stop if @owns_coordinator
        @coordinator = nil
      end

      def setup_coordinator(stage_name)
        DRb.start_service unless DRb.primary_server
        @coordinator = DRbObject.new_with_uri(@coordinator_uri)
        @coordinator.worker_count # Test connection
        Minigun.logger.info "[Cluster] Connected to coordinator at #{@coordinator_uri}"
      rescue DRb::DRbConnError
        Minigun.logger.info '[Cluster] No coordinator found, starting local coordinator'
        @coordinator = Cluster::Coordinator.new(
          bind_address: URI.parse(@coordinator_uri).host,
          port: URI.parse(@coordinator_uri).port,
          stage_name: stage_name
        )
        @coordinator.start
        @owns_coordinator = true
      end

      # === Direct Mode ===

      def execute_direct_mode(stage, input_queue, output_queue)
        DRb.start_service unless DRb.primary_server

        # Connect to all workers
        @direct_workers = @worker_uris.filter_map do |uri|
          worker = DRbObject.new_with_uri(uri)
          worker.ping # Test connection
          Minigun.logger.info "[Cluster] Connected to worker at #{uri}"
          { uri: uri, proxy: worker }
        rescue DRb::DRbConnError => e
          Minigun.logger.warn "[Cluster] Failed to connect to worker at #{uri}: #{e.message}"
          nil
        end

        if @direct_workers.empty?
          raise Cluster::Error.new('No workers available in direct mode')
        end

        Minigun.logger.info "[Cluster] Starting stage :#{stage.name} with #{@direct_workers.size} workers (direct mode)"

        begin
          distribute_and_collect_direct(stage, input_queue, output_queue)
        ensure
          shutdown_direct_mode
        end
      end

      def shutdown_direct_mode
        if @shutdown_on_done
          # Shutdown workers (for dedicated workers that should terminate after this job)
          @direct_workers.each do |w|
            Thread.new do
              Timeout.timeout(1) { w[:proxy].shutdown }
            rescue StandardError
              # Worker may be gone or unresponsive
            end
          end
          Minigun.logger.info "[Cluster] Sent shutdown to #{@direct_workers.size} workers"
        end
        # Clear our references
        @direct_workers = []
      end

      def distribute_and_collect_direct(stage, input_queue, output_queue)
        distributor = Cluster.create_distributor(
          delivery_mode: @delivery_mode,
          workers: @direct_workers,
          stage_name: stage.name,
          stage_stats: @stage_ctx.stage_stats,
          max_retries: @max_retries
        )
        distributor.distribute(input_queue, output_queue)
      end

      def distribute_and_collect_coordinator(stage, input_queue, output_queue)
        pending_count = 0
        all_sent = false
        mutex = Mutex.new
        done_cv = ConditionVariable.new

        # Thread to collect results from coordinator
        collector_thread = Thread.new do
          loop do
            break if mutex.synchronize { pending_count <= 0 && all_sent }

            result = @coordinator.collect_result(timeout: 0.1)
            next unless result

            case result[:type]
            when :result
              output_queue << result[:result]
              # Record latency if available
              @stage_ctx.stage_stats&.record_latency(result[:latency]) if result[:latency]
              mutex.synchronize do
                pending_count -= 1
                done_cv.signal if pending_count <= 0 && all_sent
              end
            when :item_done
              @stage_ctx.stage_stats&.record_latency(result[:latency]) if result[:latency]
              mutex.synchronize do
                pending_count -= 1
                done_cv.signal if pending_count <= 0 && all_sent
              end
            when :error
              # Error already logged by coordinator
              mutex.synchronize do
                pending_count -= 1
                done_cv.signal if pending_count <= 0 && all_sent
              end
            end
          end
        end

        # Distribute work items
        loop do
          item = input_queue.pop

          if item.is_a?(Minigun::EndOfStage)
            mutex.synchronize { all_sent = true }
            break
          end

          mutex.synchronize { pending_count += 1 }
          @coordinator.enqueue_work({ stage: stage.name, item: item })
        end

        # Signal end of work
        @coordinator.enqueue_end_of_stage

        # Wait for all pending items to complete
        mutex.synchronize do
          done_cv.wait(mutex, 1) until pending_count <= 0
        end

        collector_thread.join
      end
    end

    # Factory for creating executors
    def self.create_executor(type, ...)
      case type
      when :inline
        InlineExecutor.new(...)
      when :thread
        ThreadPoolExecutor.new(...)
      when :fiber
        FiberPoolExecutor.new(...)
      when :cow_fork
        CowForkPoolExecutor.new(...)
      when :ipc_fork
        IpcForkPoolExecutor.new(...)
      when :ractor
        RactorPoolExecutor.new(...)
      when :cluster
        ClusterPoolExecutor.new(...)
      else
        raise ArgumentError.new("Unknown executor type: #{type}. Valid types: :inline, :thread, :fiber, :cow_fork, :ipc_fork, :ractor, :cluster")
      end
    end
  end
end
