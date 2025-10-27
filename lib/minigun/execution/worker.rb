# frozen_string_literal: true

require_relative 'executor'

module Minigun
  module Execution
    # Unified worker for all stage types (producers and consumers)
    # Manages thread lifecycle and delegates to stage.run_worker_loop()
    class Worker
      attr_reader :thread, :stage_name, :stage

      def initialize(pipeline, stage, config = {})
        @pipeline = pipeline
        @stage = stage
        @stage_name = stage.name
        @config = config
        @thread = nil

        # Create executor only for non-producers
        @executor = create_executor_if_needed
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
        log_info "Starting"

        stage_ctx = create_stage_context
        
        # Check for disconnected stages (no upstream, not a producer, not a PipelineStage)
        if handle_disconnected_stage(stage_ctx)
          return
        end

        @stage.run_worker_loop(stage_ctx)

        log_info "Done"
      rescue => e
        log_error "Unhandled error: #{e.message}"
        log_error e.backtrace.join("\n")
      ensure
        @executor&.shutdown
      end
      
      def handle_disconnected_stage(stage_ctx)
        # Only check non-producers and non-PipelineStages
        return false if @stage.producer?
        return false if @stage.is_a?(PipelineStage)
        
        # If no upstream sources, this stage is disconnected
        if stage_ctx.sources_expected.empty?
          log_info "No upstream sources, sending END signals and exiting"
          
          # Send END to all downstream stages so they don't deadlock
          downstream = stage_ctx.dag.downstream(stage_ctx.stage_name)
          downstream.each do |target|
            stage_ctx.stage_input_queues[target] << Message.end_signal(source: stage_ctx.stage_name)
          end
          
          log_info "Done"
          return true
        end
        
        false
      end

      def create_stage_context
        dag = @pipeline.instance_variable_get(:@dag)
        stage_input_queues = @pipeline.instance_variable_get(:@stage_input_queues)

        # Calculate sources for workers (empty for producers)
        sources_expected = if @stage.producer?
                            Set.new
                          else
                            Set.new(dag.upstream(@stage_name))
                          end

        StageContext.new(
          pipeline: @pipeline,
          stage_name: @stage_name,
          dag: dag,
          runtime_edges: @pipeline.instance_variable_get(:@runtime_edges),
          stage_input_queues: stage_input_queues,
          stats: @pipeline.instance_variable_get(:@stats),
          # Worker-specific (nil/empty for producers)
          input_queue: stage_input_queues[@stage_name],
          sources_expected: sources_expected,
          sources_done: Set.new,
          executor: @executor
        )
      end

      def create_executor_if_needed
        return nil if @stage.producer?

        exec_ctx = @stage.execution_context
        return InlineExecutor.new if exec_ctx.nil?

        type = normalize_type(exec_ctx[:type])
        pool_size = exec_ctx[:pool_size] || exec_ctx[:max] || default_pool_size(exec_ctx[:type])

        Execution.create_executor(type: type, max_size: pool_size)
      end

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
        when :threads then @config[:max_threads] || 5
        when :processes then @config[:max_processes] || 2
        when :ractors then @config[:max_ractors] || 4
        else 5
        end
      end

      def log_info(msg)
        pipeline_name = @pipeline.instance_variable_get(:@name)
        worker_type = @stage.producer? ? "Producer" : "Worker"
        Minigun.logger.info "[Pipeline:#{pipeline_name}][#{worker_type}:#{@stage_name}] #{msg}"
      end

      def log_error(msg)
        pipeline_name = @pipeline.instance_variable_get(:@name)
        worker_type = @stage.producer? ? "Producer" : "Worker"
        Minigun.logger.error "[Pipeline:#{pipeline_name}][#{worker_type}:#{@stage_name}] #{msg}"
      end
    end
  end
end

