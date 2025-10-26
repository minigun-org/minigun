# frozen_string_literal: true

require_relative 'stage_executor'

module Minigun
  module Execution
    # Owns the entire stage worker lifecycle: reading from input queue, executing items, routing results
    # This is the main worker loop that was previously embedded in Pipeline#start_stage_worker
    class StageWorker
      attr_reader :stage_name, :stage, :thread

      def initialize(pipeline, stage_name, stage, config)
        @pipeline = pipeline
        @stage_name = stage_name
        @stage = stage
        @config = config
        @executor = StageExecutor.new(pipeline, config)
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
        @executor.shutdown
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
        loop do
          msg = input_queue.pop

          # Handle END signal
          if msg.is_a?(Message) && msg.end_of_stream?
            sources_expected << msg.source  # Discover dynamic source
            sources_done << msg.source
            break if sources_done == sources_expected
            next
          end

          # Execute the stage
          item = msg  # msg is unwrapped data
          item_data = { item: item, stage: @stage }
          results = @executor.execute_with_context(@stage.execution_context, [item_data])

          # Route results to downstream stages
          route_results(results, dag, runtime_edges, stage_input_queues)
        end

        # Flush accumulator stages before sending END signals
        flush_accumulator(dag, stage_input_queues) if @stage.respond_to?(:flush)

        # Send END to ALL connections: DAG downstream + dynamic emit_to_stage targets
        send_end_signals(dag, runtime_edges, stage_input_queues)
      end

      def route_results(results, dag, runtime_edges, stage_input_queues)
        results.each do |result|
          if result.is_a?(Hash) && result.key?(:item) && result.key?(:target)
            # Targeted emit via emit_to_stage - route DIRECTLY to target's input queue
            target_stage = result[:target]
            output_queue = stage_input_queues[target_stage]
            if output_queue
              runtime_edges[@stage_name].add(target_stage)
              output_queue << result[:item]
            end
          else
            # Regular emit - uses DAG routing to all downstream
            downstream = dag.downstream(@stage_name)
            downstream.each do |downstream_stage|
              output_queue = stage_input_queues[downstream_stage]
              output_queue << result if output_queue
            end
          end
        end
      end

      def flush_accumulator(dag, stage_input_queues)
        context = @pipeline.instance_variable_get(:@context)
        flushed_items = @stage.flush(context)
        flushed_items.each do |batch|
          # Route flushed batches to downstream stages
          downstream = dag.downstream(@stage_name)
          downstream.each do |downstream_stage|
            output_queue = stage_input_queues[downstream_stage]
            output_queue << batch if output_queue
          end
        end
      end

      def send_end_signals(dag, runtime_edges, stage_input_queues)
        dag_downstream = dag.downstream(@stage_name)
        dynamic_targets = runtime_edges[@stage_name].to_a
        all_targets = (dag_downstream + dynamic_targets).uniq

        all_targets.each do |target|
          stage_input_queues[target] << Message.end_signal(source: @stage_name)
        end
      end

      def log_info(message)
        pipeline_name = @pipeline.instance_variable_get(:@name)
        Minigun.logger.info "[Pipeline:#{pipeline_name}][Worker:#{@stage_name}] #{message}"
      end
    end
  end
end

