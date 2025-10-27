# frozen_string_literal: true

require_relative 'executor'

module Minigun
  module Execution
    # Owns the entire stage worker lifecycle: reading from input queue, executing items, routing results
    # Manages executors for concurrent execution strategies
    class StageWorker
      attr_reader :stage_name, :stage, :thread

      def initialize(pipeline, stage_name, stage, config)
        @pipeline = pipeline
        @stage_name = stage_name
        @stage = stage
        @config = config

        # Get context from pipeline for stage execution
        @user_context = @pipeline.instance_variable_get(:@context)
        @stats = @pipeline.instance_variable_get(:@stats)
        @stage_hooks = @pipeline.instance_variable_get(:@stage_hooks)

        # Create executor for this stage based on its execution context
        @executor = create_executor_for_stage
      end

      # Start the worker thread
      def start
        @thread = Thread.new { run_worker_loop }
      end

      # Wait for worker to complete
      def join
        @thread&.join
      end

      private

      def run_worker_loop
        log_info "Starting"

        # Get input queue for this stage
        input_queue = @pipeline.instance_variable_get(:@stage_input_queues)[@stage_name]

        unless input_queue
          log_info "No input queue, exiting"
          return
        end

        # Track sources: we know DAG upstream at start, discover dynamic sources at runtime
        dag = @pipeline.instance_variable_get(:@dag)
        dag_upstream = dag.upstream(@stage_name)
        sources_expected = Set.new(dag_upstream)
        sources_done = Set.new
        runtime_edges = @pipeline.instance_variable_get(:@runtime_edges)
        stage_input_queues = @pipeline.instance_variable_get(:@stage_input_queues)

        # If no DAG upstream and stage is a regular consumer/processor (not a producer or PipelineStage),
        # this stage is disconnected - send END signals to downstream and exit
        if sources_expected.empty? && !@stage.producer? && !@stage.is_a?(PipelineStage)
          log_info "No upstream sources, sending END signals and exiting"
          # Send END to all downstream stages so they don't deadlock waiting for this stage
          downstream = dag.downstream(@stage_name)
          downstream.each do |target|
            stage_input_queues[target] << Message.end_signal(source: @stage_name)
          end
          return
        end

        # Create worker context for the stage
        worker_ctx = WorkerContext.new(
          input_queue: input_queue,
          sources_expected: sources_expected,
          sources_done: sources_done,
          dag: dag,
          runtime_edges: runtime_edges,
          stage_input_queues: stage_input_queues,
          executor: @executor,
          pipeline: @pipeline,
          stage_name: @stage_name
        )

        # Delegate to the stage's run_worker_loop method
        @stage.run_worker_loop(worker_ctx)

        log_info "Done"
      ensure
        @executor&.shutdown
      end


      # Create executor for this stage based on its execution context
      def create_executor_for_stage
        exec_ctx = @stage.execution_context
        return InlineExecutor.new if exec_ctx.nil?

        type = normalize_type(exec_ctx[:type])
        pool_size = exec_ctx[:pool_size] || exec_ctx[:max] || default_pool_size(exec_ctx[:type])

        Execution.create_executor(type: type, max_size: pool_size)
      end

      # Execute a single item for this stage with queue wrappers

      # Normalize execution strategy type names
      def normalize_type(type)
        case type
        when :threads then :thread
        when :processes then :fork
        when :ractors then :ractor
        else type
        end
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

      def log_info(message)
        pipeline_name = @pipeline.instance_variable_get(:@name)
        Minigun.logger.info "[Pipeline:#{pipeline_name}][Worker:#{@stage_name}] #{message}"
      end
    end
  end
end

