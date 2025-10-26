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

      def shutdown
        @context_pools.each_value do |pool|
          pool.terminate_all
        end
        @context_pools.clear
      end

      # Execute a SINGLE item (called once per item from stage worker)
      def execute_item(stage, item)
        exec_ctx = stage.execution_context
        return execute_stage_item({ item: item, stage: stage }) if exec_ctx.nil?

        case exec_ctx[:mode]
        when :pool
          execute_single_item_with_pool(exec_ctx, stage, item)
        when :per_batch
          # Per-batch mode still needs the item executed immediately
          execute_stage_item({ item: item, stage: stage })
        else
          # Default: inline execution
          execute_stage_item({ item: item, stage: stage })
        end
      end

      private

      # Execute a single item using a REUSED thread/process pool
      def execute_single_item_with_pool(exec_ctx, stage, item)
        type = exec_ctx[:type]
        pool_size = exec_ctx[:pool_size] || default_pool_size(type)
        
        # Normalize type (:threads -> :thread, :processes -> :fork)
        pool_type = normalize_pool_type(type)
        
        # Get or create LONG-LIVED pool (reused across all items for this stage)
        pool = get_or_create_pool(pool_type, pool_size)
        
        case type
        when :threads
          execute_item_with_thread_pool(pool, stage, item)
        when :processes
          execute_item_with_process_pool(pool, stage, item)
        when :ractors
          execute_item_with_ractor_pool(pool, stage, item)
        else
          execute_item_with_thread_pool(pool, stage, item)
        end
      end
      
      # Normalize execution strategy type to pool type
      def normalize_pool_type(type)
        case type
        when :threads
          :thread
        when :processes
          :fork
        when :ractors
          :ractor
        else
          :thread
        end
      end

      # Execute one item using the thread pool
      def execute_item_with_thread_pool(pool, stage, item)
        # Wait for available thread
        ctx = nil
        while ctx.nil?
          if pool.at_capacity?
            sleep 0.01
          else
            ctx = pool.acquire("worker")
          end
        end
        
        # Execute in thread
        result = nil
        ctx.execute do
          result = execute_stage_item({ item: item, stage: stage })
        end
        
        ctx.join
        pool.release(ctx)
        
        result || []
      end

      # Execute one item using the process pool
      def execute_item_with_process_pool(pool, stage, item)
        unless Process.respond_to?(:fork)
          warn "[Minigun] Process forking not available, falling back to inline"
          return execute_stage_item({ item: item, stage: stage })
        end
        
        # Wait for available process slot
        ctx = nil
        while ctx.nil?
          if pool.at_capacity?
            sleep 0.01
          else
            ctx = pool.acquire("worker")
          end
        end
        
        # Execute before_fork hooks
        execute_fork_hooks(:before_fork, stage)
        
        # Execute in forked process
        ctx.execute do
          execute_fork_hooks(:after_fork, stage)
          execute_stage_item({ item: item, stage: stage })
        end
        
        result = ctx.join
        pool.release(ctx)
        
        result || []
      end

      # Execute one item using the ractor pool
      def execute_item_with_ractor_pool(pool, stage, item)
        unless defined?(::Ractor)
          warn "[Minigun] Ractors not available, falling back to thread pool"
          return execute_item_with_thread_pool(pool, stage, item)
        end
        
        # For now, fall back to threads
        execute_item_with_thread_pool(pool, stage, item)
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
