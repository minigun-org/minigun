# frozen_string_literal: true

module Minigun
  module Execution
    # Base executor class - all execution strategies inherit from this
    # Executors handle stage execution including hooks, stats, and error handling
    class Executor
      # Execute a stage item
      # @param stage [Stage] The stage to execute
      # @param item [Object] The item to process
      # @param user_context [Object] The user's pipeline context
      # @param stats [Stats] The stats object for tracking
      # @param pipeline [Pipeline] The pipeline instance (for hooks)
      # @return [Array] Results from the stage execution
      def execute_stage_item(stage:, item:, user_context:, stats:, pipeline:)
        # Check if stage is terminal
        dag = pipeline.instance_variable_get(:@dag)
        is_terminal = dag.terminal?(stage.name)
        stage_stats = stats.for_stage(stage.name, is_terminal: is_terminal)
        stage_stats.start! unless stage_stats.start_time
        start_time = Time.now

        # Execute before hooks for this stage
        pipeline.send(:execute_stage_hooks, :before, stage.name)

        # Track consumption of input item
        stage_stats.increment_consumed

        # Execute the stage using this executor's strategy
        result = execute_with_strategy(stage, item, user_context, pipeline)

        # Track production of output items
        stage_stats.increment_produced(result.size)

        # Record latency
        duration = Time.now - start_time
        stage_stats.record_latency(duration)

        # Execute after hooks for this stage
        pipeline.send(:execute_stage_hooks, :after, stage.name)

        result
      rescue => e
        Minigun.logger.error "[Pipeline:#{pipeline.name}][Stage:#{stage.name}] Error: #{e.message}"
        Minigun.logger.error e.backtrace.join("\n")
        []
      end

      # Shutdown and cleanup resources
      def shutdown
        # Default: no-op
      end

      protected

      # Execute the actual stage logic using this executor's strategy
      # Subclasses implement this to control HOW execution happens
      def execute_with_strategy(stage, item, user_context, pipeline)
        raise NotImplementedError, "#{self.class}#execute_with_strategy must be implemented"
      end

      # Run the stage's actual processing logic
      def run_stage_logic(stage, item, user_context)
        if stage.respond_to?(:execute_with_emit)
          stage.execute_with_emit(user_context, item)
        else
          stage.execute(user_context, item)
          []
        end
      end
    end

    # Inline execution - no concurrency, executes immediately in current thread
    class InlineExecutor < Executor
      protected

      def execute_with_strategy(stage, item, user_context, pipeline)
        run_stage_logic(stage, item, user_context)
      end
    end

    # Thread pool executor - manages concurrent execution with threads
    class ThreadPoolExecutor < Executor
      attr_reader :max_size

      def initialize(max_size:)
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

      def execute_with_strategy(stage, item, user_context, pipeline)
        wait_for_slot

        result = nil
        thread = Thread.new do
          begin
            result = run_stage_logic(stage, item, user_context)
          ensure
            @mutex.synchronize { @active_threads.delete(Thread.current) }
          end
        end

        @mutex.synchronize { @active_threads << thread }
        thread.value  # Wait and return result
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
        @max_size = max_size
        @active_pids = []
        @mutex = Mutex.new
      end

      def shutdown
        @mutex.synchronize { @active_pids.dup }.each do |pid|
          Process.kill('TERM', pid) rescue nil
        end
        @active_pids.clear
      end

      protected

      def execute_with_strategy(stage, item, user_context, pipeline)
        unless Process.respond_to?(:fork)
          warn "[Minigun] Process forking not available, falling back to inline"
          return run_stage_logic(stage, item, user_context)
        end

        wait_for_slot

        # Execute before_fork hooks
        execute_fork_hooks(:before_fork, stage, pipeline)

        reader, writer = IO.pipe
        pid = fork do
          reader.close

          # Execute after_fork hooks in child
          execute_fork_hooks(:after_fork, stage, pipeline)

          begin
            result = run_stage_logic(stage, item, user_context)
            Marshal.dump(result, writer)
          rescue => e
            Marshal.dump({ error: e }, writer)
          ensure
            writer.close
          end
        end

        writer.close
        @mutex.synchronize { @active_pids << pid }

        # Wait for child and get result
        Process.wait(pid)
        result = Marshal.load(reader) rescue nil
        reader.close

        @mutex.synchronize { @active_pids.delete(pid) }

        if result.is_a?(Hash) && result[:error]
          raise result[:error]
        end

        result
      end

      private

      def wait_for_slot
        loop do
          return if @mutex.synchronize { @active_pids.size } < @max_size
          sleep 0.01
        end
      end

      def execute_fork_hooks(hook_type, stage, pipeline)
        user_context = pipeline.instance_variable_get(:@context)
        stage_hooks = pipeline.instance_variable_get(:@stage_hooks)

        # Pipeline-level fork hooks
        hooks = pipeline.instance_variable_get(:@hooks)[hook_type] || []
        hooks.each { |h| user_context.instance_eval(&h) }

        # Stage-specific fork hooks
        stage_hooks_list = stage_hooks.dig(hook_type, stage.name) || []
        stage_hooks_list.each { |h| user_context.instance_exec(&h) }
      end
    end

    # Ractor pool executor - manages ractor execution
    class RactorPoolExecutor < Executor
      def initialize(max_size:)
        @max_size = max_size
        @fallback = ThreadPoolExecutor.new(max_size: max_size)
      end

      protected

      def execute_with_strategy(stage, item, user_context, pipeline)
        unless defined?(::Ractor)
          warn "[Minigun] Ractors not available, falling back to thread pool"
          return @fallback.send(:execute_with_strategy, stage, item, user_context, pipeline)
        end

        # For now, fall back to threads
        @fallback.send(:execute_with_strategy, stage, item, user_context, pipeline)
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

