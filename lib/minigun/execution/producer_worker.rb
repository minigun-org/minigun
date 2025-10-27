# frozen_string_literal: true

module Minigun
  module Execution
    # Manages producer stage execution in a dedicated thread
    # Producers execute once and send END signals when done
    class ProducerWorker
      attr_reader :thread, :stage_name

      def initialize(pipeline, producer_stage)
        @pipeline = pipeline
        @producer_stage = producer_stage
        @stage_name = producer_stage.name
        @thread = nil
      end

      # Start the producer thread
      def start
        @thread = Thread.new do
          run_producer
        end
      end

      # Wait for producer thread to complete
      def join
        @thread&.join
      end

      private

      def run_producer
        stage_stats = @pipeline.instance_variable_get(:@stats).for_stage(@stage_name, is_terminal: false)
        stage_stats.start!

        is_pipeline = @producer_stage.is_a?(PipelineStage)
        log_info "Starting #{is_pipeline ? '(nested pipeline)' : ''}"

        begin
          # Execute before hooks for this producer
          execute_hooks(:before) unless is_pipeline

          # Create OutputQueue wrapper for the new DSL
          output_queue = create_output_queue

          # Execute the producer stage
          context = @pipeline.instance_variable_get(:@context)
          @producer_stage.execute(context, item: nil, input_queue: nil, output_queue: output_queue)

          # Update stats with items produced
          output_queue.items_produced.times { stage_stats.increment_produced }

          # Execute after hooks for this producer
          execute_hooks(:after) unless is_pipeline
        rescue => e
          log_error "Error: #{e.message}"
          log_error e.backtrace.join("\n") if is_pipeline
          # Don't propagate error - other producers should continue
        ensure
          stage_stats.finish!
          log_info "Done"

          # Send END signal to ALL connections: DAG downstream + dynamic routing targets
          send_end_signals
        end
      end

      def create_output_queue
        dag = @pipeline.instance_variable_get(:@dag)
        stage_input_queues = @pipeline.instance_variable_get(:@stage_input_queues)
        runtime_edges = @pipeline.instance_variable_get(:@runtime_edges)

        downstream = dag.downstream(@stage_name)
        downstream_queues = downstream.map { |to| stage_input_queues[to] }.compact

        OutputQueue.new(@stage_name, downstream_queues, stage_input_queues, runtime_edges)
      end

      def execute_hooks(type)
        @pipeline.execute_stage_hooks(type, @stage_name)
      end

      def send_end_signals
        dag = @pipeline.instance_variable_get(:@dag)
        stage_input_queues = @pipeline.instance_variable_get(:@stage_input_queues)
        runtime_edges = @pipeline.instance_variable_get(:@runtime_edges)

        downstream = dag.downstream(@stage_name)
        dynamic_targets = runtime_edges[@stage_name].to_a
        all_targets = (downstream + dynamic_targets).uniq

        all_targets.each do |target|
          stage_input_queues[target] << Message.end_signal(source: @stage_name)
        end
      end

      def log_info(msg)
        pipeline_name = @pipeline.instance_variable_get(:@name)
        Minigun.logger.info "[Pipeline:#{pipeline_name}][Producer:#{@stage_name}] #{msg}"
      end

      def log_error(msg)
        pipeline_name = @pipeline.instance_variable_get(:@name)
        Minigun.logger.error "[Pipeline:#{pipeline_name}][Producer:#{@stage_name}] #{msg}"
      end
    end
  end
end

