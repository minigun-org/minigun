# frozen_string_literal: true

require 'concurrent'
require_relative 'context'
require_relative 'context_pool'

module Minigun
  module Execution
    # Executes stages using their assigned execution contexts
    # This is the central execution engine that replaces all the old threading/forking logic
    class StageExecutor
      def initialize(pipeline, config)
        @pipeline = pipeline
        @config = config
        @context_pools = {}
        @user_context = pipeline.instance_variable_get(:@context)
        @stats = pipeline.instance_variable_get(:@stats)
        @stage_hooks = pipeline.instance_variable_get(:@stage_hooks)
        @output_items = []
      end

      # Execute a batch of items through stages with proper execution contexts
      def execute_batch(batch_map, output_items, context, stats, stage_hooks)
        @stats = stats
        @stage_hooks = stage_hooks
        @output_items = output_items
        @user_context = context

        # Group stages by their execution context
        context_groups = group_by_execution_context(batch_map)

        # Execute each group with its appropriate execution context
        context_groups.each do |exec_ctx, stage_items|
          execute_with_context(exec_ctx, stage_items)
        end
      end

      def shutdown
        @context_pools.each_value do |pool|
          pool.terminate_all
        end
        @context_pools.clear
      end

      # Public method - execute items with their execution context
      # Returns array of emitted items
      def execute_with_context(exec_ctx, stage_items)
        # Clear output items
        @output_items.clear

        # All stages have an execution context (never nil)
        case exec_ctx[:mode]
        when :pool
          execute_with_pool(exec_ctx, stage_items)
        when :per_batch
          execute_per_batch(exec_ctx, stage_items)
        when :inline
          execute_inline(stage_items)
        else
          # Fallback to inline if mode is unknown
          execute_inline(stage_items)
        end

        # Return the collected output items
        @output_items.dup
      end

      private

      # Execute with a pool of reusable execution contexts (threads/processes/ractors)
      def execute_with_pool(exec_ctx, stage_items)
        type = exec_ctx[:type]
        pool_size = exec_ctx[:pool_size] || default_pool_size(type)

        case type
        when :threads
          execute_with_thread_pool(pool_size, stage_items)
        when :processes
          execute_with_process_pool(pool_size, stage_items)
        when :ractors
          execute_with_ractor_pool(pool_size, stage_items)
        else
          execute_with_thread_pool(pool_size, stage_items)
        end
      end

      def execute_with_thread_pool(pool_size, stage_items)
        # Use ThreadContext with a pool
        pool = get_or_create_pool(:thread, pool_size)
        contexts = []
        mutex = Mutex.new

        stage_items.each do |item_data|
          # Wait for available slot
          while pool.at_capacity?
            contexts.delete_if { |ctx| !ctx.alive? }
            sleep 0.01
          end

          # Create and execute in thread context
          ctx = pool.acquire("consumer")
          contexts << ctx

          ctx.execute do
            execute_stage_item(item_data, mutex)
          end
        end

        # Wait for all contexts to complete
        contexts.each do |ctx|
          ctx.join
          pool.release(ctx)
        end
      end

      def execute_with_process_pool(pool_size, stage_items)
        unless Process.respond_to?(:fork)
          warn "[Minigun] Process forking not available, falling back to threads"
          return execute_with_thread_pool(pool_size, stage_items)
        end

        # For process pools, we need IPC for results
        # Use ForkContext (processes type) with proper transport
        pool = get_or_create_pool(:processes, pool_size)
        contexts = []
        all_results = []

        stage_items.each do |item_data|
          # Wait for available slot
          while pool.at_capacity?
            contexts.each do |ctx|
              unless ctx.alive?
                child_results = ctx.join
                all_results.concat(child_results) if child_results.is_a?(Array)
              end
            end
            contexts.delete_if { |ctx| !ctx.alive? }
            sleep 0.01
          end

          # Execute before_fork hooks in parent
          execute_fork_hooks(:before_fork, item_data[:stage])

          ctx = pool.acquire("worker-#{item_data[:stage].name}")
          contexts << ctx

          # Capture data needed in child process
          item = item_data[:item]
          stage = item_data[:stage]
          user_context = @user_context
          stage_hooks = @stage_hooks

          # Execute in forked process with IPC
          ctx.execute do
            begin
              # Execute after_fork hooks in child
              after_hooks = stage_hooks.dig(:after_fork, stage.name) || []
              after_hooks.each { |h| user_context.instance_exec(&h) }

              # Capture emitted items in child process
              child_output_items = []

              # Execute before hooks
              before_hooks = stage_hooks.dig(:before, stage.name) || []
              before_hooks.each { |h| user_context.instance_exec(&h) }

              # Execute the stage and capture emissions
              emitted_items = stage.execute_with_emit(user_context, item)

              # Execute after hooks
              after_hooks_stage = stage_hooks.dig(:after, stage.name) || []
              after_hooks_stage.each { |h| user_context.instance_exec(&h) }

              # Return emitted items for IPC
              emitted_items
            rescue => e
              # Return error info
              { error: e.message, backtrace: e.backtrace.first(5) }
            end
          end
        end

        # Wait for all processes and collect results
        contexts.each do |ctx|
          child_results = ctx.join
          if child_results.is_a?(Hash) && child_results[:error]
            Minigun.logger.error "[ProcessPool] Child process error: #{child_results[:error]}"
            child_results[:backtrace]&.each { |line| Minigun.logger.error line }
          elsif child_results.is_a?(Array)
            all_results.concat(child_results)
          end
          pool.release(ctx)
        end

        # Add results to output_items
        all_results.each { |result| @output_items << result }
      end

      def execute_with_ractor_pool(pool_size, stage_items)
        unless defined?(::Ractor)
          warn "[Minigun] Ractors not available, falling back to thread pool"
          return execute_with_thread_pool(pool_size, stage_items)
        end

        # Ractors have restrictions on shared objects
        # For now, fall back to threads
        # TODO: Implement true ractor execution with proper message passing
        execute_with_thread_pool(pool_size, stage_items)
      end

      # Execute per-batch: spawn a new thread/process/ractor for each batch
      # This is the Copy-on-Write pattern for processes
      def execute_per_batch(exec_ctx, stage_items)
        type = exec_ctx[:type]
        max_concurrent = exec_ctx[:max] || 4

        case type
        when :threads
          execute_per_batch_threads(stage_items, max_concurrent)
        when :processes
          execute_per_batch_processes(stage_items, max_concurrent)
        when :ractors
          execute_per_batch_ractors(stage_items, max_concurrent)
        else
          execute_per_batch_threads(stage_items, max_concurrent)
        end
      end

      def execute_per_batch_threads(stage_items, max_concurrent)
        contexts = []
        mutex = Mutex.new

        stage_items.each do |item_data|
          # Wait if we're at max concurrency
          while contexts.count(&:alive?) >= max_concurrent
            contexts.delete_if { |ctx| !ctx.alive? }
            sleep 0.01
          end

          # Create new thread context for this batch
          ctx = ThreadContext.new("batch-#{contexts.size}")
          contexts << ctx

          ctx.execute do
            execute_stage_item(item_data, mutex)
          end
        end

        # Wait for all threads to complete
        contexts.each(&:join)
      end

      def execute_per_batch_processes(stage_items, max_concurrent)
        unless Process.respond_to?(:fork)
          warn "[Minigun] Process forking not available, falling back to threads"
          return execute_per_batch_threads(stage_items, max_concurrent)
        end

        contexts = []

        # Execute before_fork hooks once before any forking (for all stages)
        stage_items.each do |item_data|
          execute_fork_hooks(:before_fork, item_data[:stage])
        end

        # Trigger GC to maximize Copy-on-Write benefits
        GC.start

        stage_items.each do |item_data|
          # Wait if we're at max concurrency
          while contexts.count(&:alive?) >= max_concurrent
            contexts.each do |ctx|
              ctx.join unless ctx.alive?
            end
            contexts.delete_if { |ctx| !ctx.alive? }
            sleep 0.01
          end

          # Create new fork context for this batch (Copy-on-Write)
          ctx = ForkContext.new("batch-#{contexts.size}")
          contexts << ctx

          ctx.execute do
            # Execute after_fork hooks in child process
            execute_fork_hooks(:after_fork, item_data[:stage])

            # Execute the stage item (no mutex needed - isolated process)
            execute_stage_item(item_data, nil)

            # Return nil (terminal consumers don't emit)
            nil
          end
        end

        # Wait for all child processes
        contexts.each(&:join)
      end

      def execute_per_batch_ractors(stage_items, max_concurrent)
        unless defined?(::Ractor)
          warn "[Minigun] Ractors not available, falling back to threads"
          return execute_per_batch_threads(stage_items, max_concurrent)
        end

        # Ractors require careful handling of shared state
        # For now, fall back to threads
        # TODO: Implement proper ractor execution
        execute_per_batch_threads(stage_items, max_concurrent)
      end

      # Inline execution - no concurrency
      def execute_inline(stage_items)
        stage_items.each do |item_data|
          stage = item_data[:stage]
          item = item_data[:item]

          # Get stats
          is_terminal = @pipeline.instance_variable_get(:@dag).terminal?(stage.name)
          stage_stats = @stats.for_stage(stage.name, is_terminal: is_terminal)
          stage_stats.start! unless stage_stats.start_time
          start_time = Time.now

          # Execute before hooks
          @pipeline.send(:execute_stage_hooks, :before, stage.name)

          # Track consumption
          stage_stats.increment_consumed

          # Execute the stage
          result = if stage.respond_to?(:execute_with_emit)
            @emissions.clear
            stage.execute_with_emit(@user_context, item, @emissions)
          else
            stage.execute(@user_context, item)
            []
          end

          # Track production
          stage_stats.increment_produced(result.size)

          # Record latency
          duration = Time.now - start_time
          stage_stats.record_latency(duration)

          # Execute after hooks
          @pipeline.send(:execute_stage_hooks, :after, stage.name)

          # Add results to output
          result.each { |r| @output_items << r }
        end
      end

      def execute_stage_item(item_data, mutex)
        item = item_data[:item]
        stage = item_data[:stage]
        is_terminal = @pipeline.instance_variable_get(:@dag).terminal?(stage.name)
        stage_stats = @stats.for_stage(stage.name, is_terminal: is_terminal)
        stage_stats.start! unless stage_stats.start_time
        start_time = Time.now

        # Execute before hooks for this stage
        hooks = @stage_hooks.dig(:before, stage.name) || []
        hooks.each { |h| @user_context.instance_exec(&h) }

        # Execute the stage
        result = if stage.respond_to?(:execute_with_emit)
          @emissions.clear
          stage.execute_with_emit(@user_context, item, @emissions)
        else
          stage.execute(@user_context, item)
          []
        end

        # Track consumption and production
        stage_stats.increment_consumed
        stage_stats.increment_produced(result.size) if result.is_a?(Array)

        # Add results to output for non-terminal stages
        if mutex && result.is_a?(Array)
          result.each { |r| mutex.synchronize { @output_items << r } }
        elsif result.is_a?(Array)
          result.each { |r| @output_items << r }
        end

        # Record latency
        duration = Time.now - start_time
        stage_stats.record_latency(duration)

        # Execute after hooks for this stage
        hooks = @stage_hooks.dig(:after, stage.name) || []
        hooks.each { |h| @user_context.instance_exec(&h) }
      rescue => e
        Minigun.logger.error "[Pipeline:#{@pipeline.name}][Stage:#{stage.name}] Error: #{e.message}"
        Minigun.logger.error e.backtrace.join("\n")
      end

      def execute_fork_hooks(hook_type, stage)
        # Pipeline-level fork hooks
        hooks = @pipeline.instance_variable_get(:@hooks)[hook_type] || []
        hooks.each { |h| @user_context.instance_eval(&h) }

        # Stage-specific fork hooks
        stage_hooks = @stage_hooks.dig(hook_type, stage.name) || []
        stage_hooks.each { |h| @user_context.instance_exec(&h) }
      end

      def get_or_create_pool(type, size)
        key = [type, size]
        @context_pools[key] ||= ContextPool.new(type: type, max_size: size)
      end

      def default_context
        {
          type: :threads,
          pool_size: @config[:max_threads] || 5,
          mode: :pool
        }
      end

      def default_pool_size(type)
        case type
        when :threads
          @config[:max_threads] || 5
        when :processes
          @config[:max_processes] || 2
        when :ractors
          @config[:max_ractors] || 4
        else
          5
        end
      end
    end
  end
end
