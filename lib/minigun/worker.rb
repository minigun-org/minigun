# frozen_string_literal: true

require 'timeout'

module Minigun
  # Unified worker for all stage types (producers and consumers)
  # Manages thread lifecycle and delegates to stage.run_stage()
  class Worker
    attr_reader :thread, :stage_name, :stage, :executor

    def initialize(pipeline, stage, config = {})
      @pipeline = pipeline
      @stage = stage
      @stage_name = stage.name
      @config = config
      @thread = nil
      @executor = nil # Created later in create_stage_context
    end

    # Start the worker thread
    def start
      @thread = Thread.new { run }
    end

    # Wait for worker to complete
    def join
      @thread&.join
    end

    private

    def run
      log_debug 'Starting'

      stage_ctx = create_stage_context

      # Create executor with stage_ctx (only for non-autonomous stages)
      @executor = create_executor_if_needed(stage_ctx)

      # Check for disconnected stages (no upstream, not a producer, not a PipelineStage)
      return if handle_disconnected_stage(stage_ctx)

      stage_stats = stage_ctx.stage_stats
      stage_stats.start!

      @stage.run_stage(stage_ctx)

      stage_ctx.stage_stats.finish!
      log_debug('Done')
    rescue StandardError => e
      log_error "Unhandled error: #{e.message}"
      log_error e.backtrace.join("\n")
    ensure
      @executor&.shutdown
    end

    def handle_disconnected_stage(stage_ctx)
      # Only check streaming stages (autonomous and composite manage their own execution)
      return false unless @stage.run_mode == :streaming

      # Check if stage has DAG upstream connections
      has_upstream = !stage_ctx.sources_expected.empty?

      # If has upstream, no special handling needed
      return false if has_upstream

      # Stage has no DAG upstream - two possible scenarios:
      # 1. Truly disconnected (pipeline bug, should fail fast)
      # 2. Dynamic routing target (receives items via output.to(:stage_name))
      # Use await: option to control behavior
      await = @stage.options[:await]

      # Auto-await for fork/IPC stages (commonly used for dynamic routing)
      exec_ctx = @stage.execution_context
      is_fork_stage = exec_ctx && %i[ipc_fork cow_fork].include?(exec_ctx[:type])

      case await
      when nil
        if is_fork_stage
          # Fork stages with no upstream automatically await (common pattern for output.to routing)
          log_debug 'Fork stage with no DAG upstream, awaiting items indefinitely (auto-await)'
          false
        else
          # Default: warn + 5 second timeout
          log_warning 'Stage has no DAG upstream connections, using default 5s await timeout. ' \
                      "If this is intentional (dynamic routing via output.to(:#{@stage_name})), " \
                      "consider setting 'await: true'. " \
                      'If unintentional, check your pipeline routing.'
          wait_for_first_item(timeout: 5, stage_ctx: stage_ctx)
        end

      when true
        # Explicit infinite wait - no warning, no timeout
        log_debug 'Awaiting items indefinitely (await: true)'
        false

      when false
        # Explicit immediate shutdown - no warning
        log_debug 'Shutting down immediately (await: false, no DAG upstream)'
        graceful_shutdown(stage_ctx)
        true

      when Integer, Float
        # Explicit timeout - no warning
        log_debug "Awaiting items with #{await}s timeout (await: #{await})"
        wait_for_first_item(timeout: await, stage_ctx: stage_ctx)

      else
        log_error "Invalid await option: #{await.inspect}. Expected: true, false, or number. Using default 5s timeout."
        wait_for_first_item(timeout: 5, stage_ctx: stage_ctx)
      end
    end

    # Wait for first item to arrive via dynamic routing
    # Returns true if timed out (should shutdown), false if item received (continue)
    # TODO: This implementation looks wonky, consider alternatives
    def wait_for_first_item(timeout:, stage_ctx:)
      raw_queue = stage_ctx.input_queue

      # Try to pop with timeout using Timeout module
      begin
        Timeout.timeout(timeout) do
          # Use Queue's non-blocking pop with a loop and small sleep
          # to avoid spinning while still being responsive
          loop do
            # Try non-blocking pop
            item = raw_queue.pop(true)

            # Got an item! Push it back so run_stage can process it
            raw_queue.push(item)
            log_debug "Received item within #{timeout}s timeout, continuing normal operation"
            return false
          rescue ThreadError
            # Queue is empty, sleep briefly and retry
            sleep 0.1
          end
        end
      rescue Timeout::Error
        # Timeout expired with no items
        log_debug "Timeout after #{timeout}s with no items, shutting down gracefully"
        graceful_shutdown(stage_ctx)
        true
      end
    end

    # Gracefully shutdown stage by sending END signals to downstream
    def graceful_shutdown(stage_ctx)
      log_debug 'Sending END signals to downstream stages'

      # Send EndOfSource to all downstream stages so they don't deadlock
      task = stage_ctx.stage.task
      dag = stage_ctx.dag
      downstream = dag.downstream(stage_ctx.stage)

      downstream.each do |target|
        queue = task&.find_queue(target)
        queue&.<< EndOfSource.new(stage_ctx.stage)
      end

      log_debug 'Graceful shutdown complete'
    end

    def create_stage_context
      dag = @pipeline.dag
      task = @pipeline.task

      # Calculate sources for workers (empty for autonomous stages)
      # DAG now uses Stage objects instead of names
      sources_expected = if @stage.run_mode == :autonomous
                           Set.new
                         else
                           # Check if this stage is an entrance router or single entry stage for nested pipeline
                           input_queues = @pipeline.input_queues
                           entrance_router = @pipeline.entrance_router

                           if @stage == entrance_router && input_queues
                             # For entrance router, use sources from parent pipeline
                             input_queues[:sources_expected] || Set.new
                           elsif dag.upstream(@stage).empty? && input_queues && input_queues[:sources_expected]
                             # For single entry stage with no upstream, use sources from parent pipeline if available
                             input_queues[:sources_expected]
                           else
                             Set.new(dag.upstream(@stage))
                           end
                         end

      # Create stats object for this specific stage
      # DAG now uses Stage objects
      is_terminal = dag.terminal?(@stage)
      stage_stats = @pipeline.stats.for_stage(@stage, is_terminal: is_terminal)

      StageContext.new(
        worker: self,
        stage: @stage,
        dag: dag,
        runtime_edges: @pipeline.runtime_edges,
        stage_stats: stage_stats,
        # Worker-specific (nil/empty for producers)
        input_queue: task&.find_queue(@stage),
        sources_expected: sources_expected,
        sources_done: Set.new
      )
    end

    def create_executor_if_needed(stage_ctx)
      return nil if @stage.run_mode == :autonomous

      exec_ctx = @stage.execution_context
      return Execution::InlineExecutor.new(stage_ctx) if exec_ctx.nil?

      type = exec_ctx[:type]
      pool_size = exec_ctx[:pool_size] || exec_ctx[:max] || default_pool_size(type)

      Execution.create_executor(type, stage_ctx, max_size: pool_size)
    end

    # TODO: Move this elsewhere? DSL class?
    def default_pool_size(type)
      case type
      when :thread then @config[:max_threads] || 5
      when :cow_fork then @config[:max_processes] || 2
      when :ipc_fork then @config[:max_processes] || 2
      when :ractor then @config[:max_ractors] || 4
      else 5
      end
    end

    def log_debug(msg)
      Minigun.logger.debug "[Pipeline:#{@pipeline.name}][#{@stage.log_type}:#{@stage_name}] #{msg}"
    end

    def log_warning(msg)
      Minigun.logger.warn "[Pipeline:#{@pipeline.name}][#{@stage.log_type}:#{@stage_name}] #{msg}"
    end

    def log_error(msg)
      Minigun.logger.error "[Pipeline:#{@pipeline.name}][#{@stage.log_type}:#{@stage_name}] #{msg}"
    end
  end
end
