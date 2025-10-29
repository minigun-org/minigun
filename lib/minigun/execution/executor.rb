# frozen_string_literal: true

module Minigun
  # Execution strategies for running pipeline stages
  module Execution
    # Base executor class - all execution strategies inherit from this
    # NOTE: Stages now manage their own execution loops internally via execute(context, input_queue, output_queue).
    # Executors define HOW that execution happens (inline, threaded, etc).
    class Executor
      # Execute a stage with stats tracking, hooks, and error handling
      # This is the main entry point for executing stages
      def execute_stage(stage:, user_context:, input_queue:, output_queue:, stats:, pipeline:)
        # Get stage stats for tracking
        dag = pipeline.dag
        is_terminal = dag.terminal?(stage.name)
        stage_stats = stats.for_stage(stage.name, is_terminal: is_terminal)
        stage_stats.start! unless stage_stats.start_time
        start_time = Time.now

        # Execute before hooks for this stage
        pipeline.send(:execute_stage_hooks, :before, stage.name)

        # Execute the stage using this executor's strategy
        execute_with_strategy(stage, user_context, input_queue, output_queue)

        # Record latency for the entire stage execution
        duration = Time.now - start_time
        stage_stats.record_latency(duration)

        # Execute after hooks for this stage
        pipeline.send(:execute_stage_hooks, :after, stage.name)
      rescue StandardError => e
        Minigun.logger.error "[Pipeline:#{pipeline.name}][Stage:#{stage.name}] Error: #{e.message}"
        Minigun.logger.error e.backtrace.join("\n")
      end

      # Shutdown and cleanup resources
      def shutdown
        # Default: no-op
      end

      protected

      # Execute the actual stage logic using this executor's strategy
      # Subclasses implement this to control HOW execution happens
      # All stages now have unified signature: execute(context, input_queue, output_queue)
      def execute_with_strategy(stage, user_context, input_queue, output_queue)
        raise NotImplementedError, "#{self.class}#execute_with_strategy must be implemented"
      end
    end

    # Inline execution - no concurrency, executes immediately in current thread
    class InlineExecutor < Executor
      protected

      def execute_with_strategy(stage, user_context, input_queue, output_queue)
        stage.execute(user_context, input_queue, output_queue)
      end
    end

    # Thread pool executor - manages concurrent execution with threads
    class ThreadPoolExecutor < Executor
      attr_reader :max_size

      def initialize(max_size:)
        super()
        @max_size = max_size
        @active_threads = []
        @mutex = Mutex.new
      end

      def shutdown
        @mutex.synchronize { @active_threads.dup }.each do |thread|
          thread.kill if thread.alive?
        end
        @active_threads.clear
      end

      protected

      def execute_with_strategy(stage, user_context, input_queue, output_queue)
        wait_for_slot

        thread = Thread.new do
          stage.execute(user_context, input_queue, output_queue)
        ensure
          @mutex.synchronize { @active_threads.delete(Thread.current) }
        end

        @mutex.synchronize { @active_threads << thread }
        thread.value # Wait for completion
      end

      private

      def wait_for_slot
        loop do
          return if @mutex.synchronize { @active_threads.size } < @max_size

          sleep 0.01
        end
      end
    end

    # Process pool executor - manages forked process execution
    class ProcessPoolExecutor < Executor
      attr_reader :max_size

      def initialize(max_size:)
        super()
        @max_size = max_size
        @active_pids = []
        @mutex = Mutex.new
      end

      def shutdown
        @mutex.synchronize { @active_pids.dup }.each do |pid|
          Process.kill('TERM', pid)
        rescue StandardError
          nil
        end
        @active_pids.clear
      end

      protected

      def execute_with_strategy(stage, user_context, input_queue, output_queue)
        unless Process.respond_to?(:fork)
          warn '[Minigun] Process forking not available, falling back to inline'
          return stage.execute(user_context, input_queue, output_queue)
        end

        # NOTE: Queue-based DSL doesn't work with process pools since queues can't cross process boundaries
        # This would require implementing IPC for queue operations
        # For now, process pools execute stages but can't properly route via queues
        raise NotImplementedError, 'Process pools are not yet compatible with queue-based DSL. Use threads or inline execution.'

        # Keeping old implementation commented for reference
        # wait_for_slot
        #
        # # Execute before_fork hooks
        # execute_fork_hooks(:before_fork, stage, pipeline)
        #
        # reader, writer = IO.pipe
        # pid = fork do
        #   reader.close
        #
        #   # Execute after_fork hooks in child
        #   execute_fork_hooks(:after_fork, stage, pipeline)
        #
        #   begin
        #     run_stage_logic(stage, item, user_context, input_queue, output_queue)
        #     Marshal.dump(:success, writer)
        #   rescue => e
        #     Marshal.dump({ error: e }, writer)
        #   ensure
        #     writer.close
        #   end
        # end
        #
        # writer.close
        # @mutex.synchronize { @active_pids << pid }
        #
        # # Wait for child
        # Process.wait(pid)
        # result = Marshal.load(reader) rescue nil
        # reader.close
        #
        # @mutex.synchronize { @active_pids.delete(pid) }
        #
        # if result.is_a?(Hash) && result[:error]
        #   raise result[:error]
        # end
      end
      #
      # private
      #
      # def wait_for_slot
      #   loop do
      #     return if @mutex.synchronize { @active_pids.size } < @max_size
      #
      #     sleep 0.01
      #   end
      # end
      #
      # def execute_fork_hooks(hook_type, stage, pipeline)
      #   user_context = pipeline.context
      #   stage_hooks = pipeline.stage_hooks
      #
      #   # Pipeline-level fork hooks
      #   hooks = pipeline.hooks[hook_type] || []
      #   hooks.each { |h| user_context.instance_eval(&h) }
      #
      #   # Stage-specific fork hooks
      #   stage_hooks_list = stage_hooks.dig(hook_type, stage.name) || []
      #   stage_hooks_list.each { |h| user_context.instance_exec(&h) }
      # end
    end

    # Ractor pool executor - manages ractor execution
    class RactorPoolExecutor < Executor
      def initialize(max_size:)
        super()
        @max_size = max_size
        @fallback = ThreadPoolExecutor.new(max_size: max_size)
      end

      protected

      def execute_with_strategy(stage, user_context, input_queue, output_queue)
        unless defined?(::Ractor)
          warn '[Minigun] Ractors not available, falling back to thread pool'
          return @fallback.send(:execute_with_strategy, stage, user_context, input_queue, output_queue)
        end

        # NOTE: Ractors have similar IPC challenges as process pools
        # Fall back to threads for now
        @fallback.send(:execute_with_strategy, stage, user_context, input_queue, output_queue)
      end
    end

    # Factory for creating executors
    def self.create_executor(type:, max_size:)
      case type
      when :inline
        InlineExecutor.new
      when :thread
        ThreadPoolExecutor.new(max_size: max_size)
      when :fork
        ProcessPoolExecutor.new(max_size: max_size)
      when :ractor
        RactorPoolExecutor.new(max_size: max_size)
      else
        raise ArgumentError, "Unknown executor type: #{type}"
      end
    end
  end
end
