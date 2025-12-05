# frozen_string_literal: true

module Minigun
  # The Runner class handles the full lifecycle of a Minigun job
  # Including signal handling, statistics, and cleanup
  #
  # Graceful Shutdown:
  # - First Ctrl+C: Initiates graceful shutdown (producers stop, pipeline drains)
  # - Second Ctrl+C: Forces immediate exit (kills all child processes/threads)
  class Runner
    attr_reader :job_id, :task, :context

    # Shutdown states:
    # - :running   Normal execution
    # - :graceful  First signal received, draining pipeline
    # - :forced    Second signal received, killing everything
    SHUTDOWN_STATES = %i[running graceful forced].freeze

    def initialize(task, context)
      @task = task
      @context = context
      @job_id = SecureRandom.hex(4)
      @job_start = nil
      @job_end = nil
      @original_handlers = {}
      @pipeline_stats = [] # Collect stats from all pipelines

      # Graceful shutdown state (use symbols for atomic read/write)
      @shutdown_state = :running
      @current_pipeline = nil

      setup_signal_handlers
    end

    # Check if shutdown has been requested
    def shutdown_requested?
      @shutdown_state != :running
    end

    # Check if force shutdown has been requested
    def force_shutdown?
      @shutdown_state == :forced
    end

    # Run the task with full lifecycle management
    def run
      log_job_started

      # Run before_run hooks
      @task.root_pipeline.hooks[:before_run].each do |hook|
        @context.instance_eval(&hook)
      end

      # Execute pipeline(s)
      @job_start = Time.now

      # Just run the root pipeline - it handles all stages including PipelineStages
      result = run_single_pipeline

      @job_end = Time.now

      # Run after_run hooks
      @task.root_pipeline.hooks[:after_run].each do |hook|
        @context.instance_eval(&hook)
      end

      log_job_finished
      result
    ensure
      cleanup
    end

    private

    def run_single_pipeline
      # Pass job_id to pipeline for logging
      pipeline = @task.root_pipeline

      # Track current pipeline for shutdown coordination
      @current_pipeline = pipeline

      # Pass runner reference to pipeline for shutdown checking
      result = pipeline.run(@context, job_id: @job_id, runner: self)

      # Collect statistics
      @pipeline_stats << pipeline.stats if pipeline.stats

      result
    ensure
      @current_pipeline = nil
    end

    def setup_signal_handlers
      # Only set up handlers in the main process
      return if defined?(@in_child_process) && @in_child_process

      # Use OS-agnostic signal handling
      signals = RUBY_PLATFORM.match?(/win32|mingw/) ? %i[INT TERM] : %i[INT TERM QUIT]

      signals.each do |signal|
        @original_handlers[signal] = ::Signal.trap(signal) do
          shutdown_gracefully(signal)
        end
      end
    end

    def shutdown_gracefully(signal)
      # Note: This runs in trap context, so we can't use mutex.
      # Use atomic operations instead.
      case @shutdown_state
      when :running
        # First signal: initiate graceful shutdown
        @shutdown_state = :graceful
        initiate_graceful_shutdown(signal)
      when :graceful
        # Second signal: force quit
        @shutdown_state = :forced
        force_quit(signal)
      when :forced
        # Already forcing, just re-raise
        force_quit(signal)
      end
    end

    def initiate_graceful_shutdown(signal)
      log_debug "[Job:#{@job_id}] Received #{signal} signal, initiating graceful shutdown..."
      log_debug "[Job:#{@job_id}] Press Ctrl+C again to force quit"

      # Request shutdown from the current pipeline
      # This will propagate to all workers and stages
      @current_pipeline&.request_shutdown(force: false)
    end

    def force_quit(signal)
      log_debug "[Job:#{@job_id}] Received second #{signal} signal, forcing immediate exit..."

      # Force shutdown the current pipeline (kills all children)
      @current_pipeline&.request_shutdown(force: true)

      # Give a moment for cleanup
      sleep(0.1)

      # Restore original signal handlers and re-raise signal
      @original_handlers.each do |sig, handler|
        Signal.trap(sig, handler)
      end

      Process.kill(signal, Process.pid)
    end

    def cleanup
      # Restore signal handlers
      @original_handlers.each do |sig, handler|
        Signal.trap(sig, handler) if handler
      rescue ArgumentError
        # Signal not supported on this platform
      end
    end

    def log_job_started
      log_debug "[Job:#{@job_id}] #{@context.class.name} started"
      log_debug "[Job:#{@job_id}] Configuration: #{format_config}"
    end

    def log_job_finished
      return unless @job_start && @job_end

      runtime = @job_end - @job_start

      log_debug "[Job:#{@job_id}] #{@context.class.name} finished"
      log_debug "[Job:#{@job_id}] Runtime: #{runtime.round(2)}s"

      # Log statistics from each pipeline
      @pipeline_stats.each do |stats|
        log_debug "[Job:#{@job_id}] Pipeline '#{stats.pipeline_name}': " \
                  "#{stats.total_produced} produced, #{stats.total_consumed} consumed, " \
                  "#{stats.throughput.round(2)} items/s"

        # Log bottleneck if found
        if (bn = stats.bottleneck)
          log_debug "[Job:#{@job_id}] Bottleneck: #{bn.stage_name} (#{bn.throughput.round(2)} items/s)"
        end
      end

      # Log overall job statistics
      total_items = @pipeline_stats.sum { |s| s.total_produced }
      overall_rate = total_items / [runtime / 60.0, 0.01].max # items/min

      log_debug "[Job:#{@job_id}] Total: #{total_items} items, #{overall_rate.round(2)} items/min"
    end

    def format_config
      config = @task.config
      parts = []
      parts << "max_processes=#{config[:max_processes]}"
      parts << "max_threads=#{config[:max_threads]}"
      parts.join(', ')
    end

    def log_debug(msg)
      Minigun.logger.debug(msg)
    end

    def log_error(msg)
      Minigun.logger.error(msg)
    end
  end
end
