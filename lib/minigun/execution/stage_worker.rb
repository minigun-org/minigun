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

        # Route based on stage type
        if @stage.respond_to?(:router?) && @stage.router?
          run_router_loop(input_queue, sources_expected, sources_done, stage_input_queues)
        else
          run_processor_loop(input_queue, sources_expected, sources_done, dag, runtime_edges, stage_input_queues)
        end

        log_info "Done"
      ensure
        @executor&.shutdown
      end

      # Router stage: routes items without executing them
      def run_router_loop(input_queue, sources_expected, sources_done, stage_input_queues)
        target_queues = @stage.targets.map { |target| stage_input_queues[target] }

        if @stage.round_robin?
          # Round-robin load balancing
          round_robin_index = 0

          loop do
            msg = input_queue.pop

            # Handle END signal
            if msg.is_a?(Message) && msg.end_of_stream?
              sources_expected << msg.source  # Discover dynamic source
              sources_done << msg.source
              break if sources_done == sources_expected
              next
            end

            # Round-robin to downstream stages
            target = @stage.targets[round_robin_index]
            target_queues[round_robin_index] << msg
            round_robin_index = (round_robin_index + 1) % target_queues.size
          end
        else
          # Broadcast (default)
          loop do
            msg = input_queue.pop

            # Handle END signal
            if msg.is_a?(Message) && msg.end_of_stream?
              sources_expected << msg.source  # Discover dynamic source
              sources_done << msg.source
              break if sources_done == sources_expected
              next
            end

            # Broadcast to all downstream stages (fan-out semantics)
            @stage.targets.each do |target|
              stage_input_queues[target] << msg
            end
          end
        end

        # Broadcast END to ALL router targets (even for round-robin)
        @stage.targets.each do |target|
          stage_input_queues[target] << Message.end_signal(source: @stage_name)
        end
      end

      # Regular processor/consumer stage: executes items and routes results
      def run_processor_loop(input_queue, sources_expected, sources_done, dag, runtime_edges, stage_input_queues)
        # Create wrapped queues for the new DSL
        wrapped_input = create_input_queue_wrapper(input_queue, sources_expected)
        wrapped_output = create_output_queue_wrapper(dag, runtime_edges, stage_input_queues)

        # If stage has input loop, pass both queues and let it manage its own loop
        if @stage.stage_with_loop?
          execute_stage_with_queues(@stage, input_queue: wrapped_input, output_queue: wrapped_output)

          # Flush accumulator stages before sending END signals
          flush_stage(wrapped_output) if @stage.respond_to?(:flush)

          # Send END signals
          send_end_signals(dag, runtime_edges, stage_input_queues)
        else
          # Traditional item-by-item processing
          loop do
            msg = input_queue.pop

            # Handle END signal
            if msg.is_a?(Message) && msg.end_of_stream?
              sources_expected << msg.source  # Discover dynamic source
              sources_done << msg.source
              break if sources_done == sources_expected
              next
            end

            # Execute the stage with queue wrappers (stages push to output directly)
            item = msg  # msg is unwrapped data
            execute_stage_item(@stage, item, input_queue: nil, output_queue: wrapped_output)
          end

          # Flush accumulator stages before sending END signals
          flush_stage(wrapped_output) if @stage.respond_to?(:flush)

          # Send END to ALL connections: DAG downstream + dynamic emit_to_stage targets
          send_end_signals(dag, runtime_edges, stage_input_queues)
        end
      end

      def flush_stage(output_queue_wrapper)
        context = @pipeline.instance_variable_get(:@context)
        @stage.flush(context, output_queue_wrapper)
      end

      def send_end_signals(dag, runtime_edges, stage_input_queues)
        dag_downstream = dag.downstream(@stage_name)
        dynamic_targets = runtime_edges[@stage_name].to_a
        all_targets = (dag_downstream + dynamic_targets).uniq

        all_targets.each do |target|
          # Skip if target doesn't have an input queue (e.g., producers)
          next unless stage_input_queues[target]

          stage_input_queues[target] << Message.end_signal(source: @stage_name)
        end
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
      def execute_stage_item(stage, item, input_queue: nil, output_queue: nil)
        @executor.execute_stage_item(
          stage: stage,
          item: item,
          user_context: @user_context,
          input_queue: input_queue,
          output_queue: output_queue,
          stats: @stats,
          pipeline: @pipeline
        )
      end

      # Execute a stage that manages its own input loop
      def execute_stage_with_queues(stage, input_queue:, output_queue:)
        @executor.execute_stage_item(
          stage: stage,
          item: nil,
          user_context: @user_context,
          input_queue: input_queue,
          output_queue: output_queue,
          stats: @stats,
          pipeline: @pipeline
        )
      end

      # Create InputQueue wrapper for the new DSL
      def create_input_queue_wrapper(raw_queue, sources_expected)
        InputQueue.new(raw_queue, @stage_name, sources_expected)
      end

      # Create OutputQueue wrapper for the new DSL
      def create_output_queue_wrapper(dag, runtime_edges, stage_input_queues)
        downstream = dag.downstream(@stage_name)
        downstream_queues = downstream.map { |target| stage_input_queues[target] }.compact
        OutputQueue.new(@stage_name, downstream_queues, stage_input_queues, runtime_edges)
      end

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

