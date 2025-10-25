# frozen_string_literal: true

require 'securerandom'

module Minigun
  # The Runner class handles the full lifecycle of a Minigun job
  # Including signal handling, statistics, and cleanup
  class Runner
    attr_reader :job_id, :task, :context

    def initialize(task, context)
      @task = task
      @context = context
      @job_id = SecureRandom.hex(4)
      @job_start = nil
      @job_end = nil
      @original_handlers = {}
      @pipeline_stats = []  # Collect stats from all pipelines

      setup_signal_handlers
    end

    # Run the task with full lifecycle management
    def run
      log_job_started

      # Run before_run hooks
      @task.implicit_pipeline.hooks[:before_run].each do |hook|
        @context.instance_eval(&hook)
      end

      # Execute pipeline(s)
      @job_start = Time.now

      result = if @task.pipelines.empty?
                 # Single-pipeline mode
                 run_single_pipeline
               else
                 # Multi-pipeline mode
                 run_multi_pipeline
               end

      @job_end = Time.now

      # Run after_run hooks
      @task.implicit_pipeline.hooks[:after_run].each do |hook|
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
      pipeline = @task.implicit_pipeline
      pipeline.instance_variable_set(:@job_id, @job_id)
      result = pipeline.run(@context)

      # Collect statistics
      @pipeline_stats << pipeline.stats if pipeline.stats

      result
    end

    def run_multi_pipeline
      # Build pipeline routing
      @task.send(:build_pipeline_routing!)

      # Create inter-pipeline queues
      @task.send(:setup_inter_pipeline_queues)

      # Pass job_id to all pipelines for logging
      @task.pipelines.each do |_, pipeline|
        pipeline.instance_variable_set(:@job_id, @job_id)
      end

      # Start all pipelines in threads
      threads = @task.pipelines.map do |name, pipeline|
        pipeline.run_in_thread(@context)
      end

      # Wait for all pipelines to complete
      threads.each(&:join)

      # Collect statistics from all pipelines
      @task.pipelines.each do |_, pipeline|
        @pipeline_stats << pipeline.stats if pipeline.stats
      end

      log_info "[Job:#{@job_id}] Multi-pipeline task completed"
    end

    def setup_signal_handlers
      # Only set up handlers in the main process
      return if defined?(@in_child_process) && @in_child_process

      # Use OS-agnostic signal handling
      signals = RUBY_PLATFORM.match?(/win32|mingw/) ? %i[INT TERM] : %i[INT TERM QUIT]

      signals.each do |signal|
        @original_handlers[signal] = Signal.trap(signal) do
          shutdown_gracefully(signal)
        end
      end
    end

    def shutdown_gracefully(signal)
      log_info "[Job:#{@job_id}] Received #{signal} signal, shutting down gracefully..."

      # TODO: Send signal to all child processes tracked by pipelines
      # This will require tracking PIDs at the Runner level

      # Wait a bit for children to exit
      sleep(0.5)

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
      log_info "[Job:#{@job_id}] #{@context.class.name} started"
      log_info "[Job:#{@job_id}] Configuration: #{format_config}"
    end

    def log_job_finished
      return unless @job_start && @job_end

      runtime = @job_end - @job_start

      log_info "[Job:#{@job_id}] #{@context.class.name} finished"
      log_info "[Job:#{@job_id}] Runtime: #{runtime.round(2)}s"

      # Log statistics from each pipeline
      @pipeline_stats.each do |stats|
        log_info "[Job:#{@job_id}] Pipeline '#{stats.pipeline_name}': " \
                 "#{stats.total_produced} produced, #{stats.total_consumed} consumed, " \
                 "#{stats.throughput.round(2)} items/s"

        # Log bottleneck if found
        if (bn = stats.bottleneck)
          log_info "[Job:#{@job_id}] Bottleneck: #{bn.stage_name} (#{bn.throughput.round(2)} items/s)"
        end
      end

      # Log overall job statistics
      total_items = @pipeline_stats.sum(&:total_produced)
      overall_rate = total_items / [runtime / 60.0, 0.01].max # items/min

      log_info "[Job:#{@job_id}] Total: #{total_items} items, #{overall_rate.round(2)} items/min"
    end

    def format_config
      config = @task.config
      parts = []
      parts << "max_processes=#{config[:max_processes]}"
      parts << "max_threads=#{config[:max_threads]}"
      parts.join(', ')
    end

    def log_info(msg)
      Minigun.logger.info(msg)
    end

    def log_error(msg)
      Minigun.logger.error(msg)
    end
  end
end

