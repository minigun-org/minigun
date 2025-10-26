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

        # Get context from pipeline
        @user_context = @pipeline.instance_variable_get(:@context)
        @stats = @pipeline.instance_variable_get(:@stats)
        @stage_hooks = @pipeline.instance_variable_get(:@stage_hooks)
        @output_items = []
      end

      # Execute a batch of items through stages with proper execution contexts
      def execute_batch(batch_map, output_items, context, stats, stage_hooks)
        # Update instance variables for this batch
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

      def execute_with_context(exec_ctx, stage_items)
        return execute_inline(stage_items) if exec_ctx.nil?

        case exec_ctx[:mode]
        when :pool
          execute_with_pool(exec_ctx, stage_items)
        when :per_batch
          execute_per_batch(exec_ctx, stage_items)
        else
          # Default: inline execution
          execute_inline(stage_items)
        end
      ensure
        # Always clean up context pools
        shutdown
      end

      private

      def group_by_execution_context(batch_map)
        groups = Hash.new { |h, k| h[k] = [] }

        batch_map.each do |_consumer_name, item_data_array|
          item_data_array.each do |item_data|
            stage = item_data[:stage]
            exec_ctx = stage.execution_context || default_context
            groups[exec_ctx] << item_data
          end
        end

        groups
      end

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
            execute_stage_item(item_data)
          end
        end

        # Wait for all contexts to complete
        contexts.each do |ctx|
          ctx.join
          pool.release(ctx)
        end

        []
      end

      def execute_with_process_pool(pool_size, stage_items)
        unless Process.respond_to?(:fork)
          warn "[Minigun] Process forking not available, falling back to threads"
          return execute_with_thread_pool(pool_size, stage_items)
        end

        # For process pools, we need IPC for results
        # Use ForkContext with proper transport
        pool = get_or_create_pool(:fork, pool_size)
        contexts = []
        results = []

        stage_items.each do |item_data|
          # Wait for available slot
          while pool.at_capacity?
            contexts.each do |ctx|
              unless ctx.alive?
                results << ctx.join
              end
            end
            contexts.delete_if { |ctx| !ctx.alive? }
            sleep 0.01
          end

          # Execute before_fork hooks once
          execute_fork_hooks(:before_fork, item_data[:stage])

          ctx = pool.acquire("consumer")
          contexts << ctx

          # Execute in forked process with IPC
          ctx.execute do
            # Execute after_fork hooks in child
            execute_fork_hooks(:after_fork, item_data[:stage])

            # Execute the stage and capture results
            execute_stage_item(item_data)

            # Return nil for terminal consumers (no results to send back)
            nil
          end
        end

        # Wait for all processes and collect results
        contexts.each do |ctx|
          result = ctx.join
          results << result if result
          pool.release(ctx)
        end

        results
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
            execute_stage_item(item_data)
          end
        end

        # Wait for all threads to complete
        contexts.each(&:join)

        []
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
            execute_stage_item(item_data)

            # Return nil (terminal consumers don't emit)
            nil
          end
        end

        # Wait for all child processes
        contexts.each(&:join)

        []
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
        results = []

        stage_items.each do |item_data|
          item_results = execute_stage_item(item_data)
          results.concat(item_results) if item_results
        end

        results
      end

      def execute_stage_item(item_data)
        item = item_data[:item]
        stage = item_data[:stage]

        # Check if stage is terminal
        is_terminal = @pipeline.instance_variable_get(:@dag).terminal?(stage.name)
        stage_stats = @stats.for_stage(stage.name, is_terminal: is_terminal)
        stage_stats.start! unless stage_stats.start_time
        start_time = Time.now

        # Execute before hooks for this stage
        @pipeline.send(:execute_stage_hooks, :before, stage.name)

        # Track consumption of input item
        stage_stats.increment_consumed

        # Execute the stage
        result = if stage.respond_to?(:execute_with_emit)
          stage.execute_with_emit(@user_context, item)
        else
          stage.execute(@user_context, item)
          []
        end

        # Track production of output items
        stage_stats.increment_produced(result.size)

        # Record latency
        duration = Time.now - start_time
        stage_stats.record_latency(duration)

        # Execute after hooks for this stage
        @pipeline.send(:execute_stage_hooks, :after, stage.name)

        result
      rescue => e
        Minigun.logger.error "[Pipeline:#{@pipeline.name}][Stage:#{stage.name}] Error: #{e.message}"
        Minigun.logger.error e.backtrace.join("\n")
        []
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
