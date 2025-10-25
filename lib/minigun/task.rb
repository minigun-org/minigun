# frozen_string_literal: true

module Minigun
  # Task orchestrates one or more pipelines
  # Supports both single-pipeline (implicit) and multi-pipeline modes
  class Task
    attr_reader :config, :pipelines, :pipeline_dag, :current_pipeline

    def initialize
      @config = {
        max_threads: 5,
        max_processes: 2,
        max_retries: 3,
        accumulator_max_single: 2000,
        accumulator_max_all: 4000,
        accumulator_check_interval: 100,
        use_ipc: false
      }

      @pipelines = {}  # { pipeline_name => Pipeline }
      @pipeline_dag = DAG.new  # Pipeline-level routing
      @current_pipeline = nil  # For implicit single-pipeline mode
      @mode = :single  # :single or :multi
    end

    # Set config value (applies to all pipelines)
    def set_config(key, value)
      @config[key] = value
    end

    # Get or create a pipeline by name
    # If name is nil, use default pipeline for backward compatibility
    def get_or_create_pipeline(name = nil)
      if name.nil?
        # Implicit single-pipeline mode
        @mode = :single
        name = :default
      else
        # Explicit multi-pipeline mode
        @mode = :multi
      end

      @pipelines[name] ||= begin
        pipeline = Pipeline.new(name, @config)
        @pipeline_dag.add_node(name)
        pipeline
      end

      @current_pipeline = @pipelines[name]
      @current_pipeline
    end

    # Add a stage to the current pipeline (for backward compatibility)
    def add_stage(type, stage_name, options = {}, &block)
      pipeline = get_or_create_pipeline
      pipeline.add_stage(type, stage_name, options, &block)
    end

    # Add a hook to the current pipeline (for backward compatibility)
    def add_hook(type, &block)
      pipeline = get_or_create_pipeline
      pipeline.add_hook(type, &block)
    end

    # Define a named pipeline with routing
    def define_pipeline(name, options = {}, &block)
      @mode = :multi

      pipeline = get_or_create_pipeline(name)

      # Extract pipeline-level routing
      to_targets = options[:to]
      if to_targets
        Array(to_targets).each do |target|
          @pipeline_dag.add_edge(name, target)
        end
      end

      # Execute block in context of pipeline definition
      if block_given?
        yield pipeline
      end

      pipeline
    end

    # Run the task (single or multi-pipeline)
    def run(context)
      if @mode == :single
        run_single_pipeline(context)
      else
        run_multi_pipeline(context)
      end
    end

    # Access stages for backward compatibility
    def stages
      get_or_create_pipeline.stages
    end

    # Access hooks for backward compatibility
    def hooks
      get_or_create_pipeline.hooks
    end

    # Access DAG for backward compatibility (stage-level DAG)
    def dag
      get_or_create_pipeline.dag
    end

    private

    def run_single_pipeline(context)
      # Backward compatible: run single pipeline directly
      pipeline = get_or_create_pipeline
      pipeline.run(context)
    end

    def run_multi_pipeline(context)
      log_info "Starting multi-pipeline task with #{@pipelines.size} pipelines"

      # Build pipeline routing
      build_pipeline_routing!

      # Create inter-pipeline queues
      setup_inter_pipeline_queues

      # Start all pipelines in threads
      threads = @pipelines.map do |name, pipeline|
        pipeline.run_in_thread(context)
      end

      # Wait for all pipelines to complete
      threads.each(&:join)

      log_info "Multi-pipeline task completed"
    end

    def build_pipeline_routing!
      # If no explicit routing, build sequential pipeline connections
      if @pipeline_dag.edges.values.all?(&:empty?)
        @pipeline_dag.build_sequential!
      end

      @pipeline_dag.validate!

      log_info "Pipeline DAG: #{@pipeline_dag.nodes.join(' -> ')}"
    end

    def setup_inter_pipeline_queues
      # Create queues between connected pipelines
      @pipeline_dag.edges.each do |from_name, to_names|
        from_pipeline = @pipelines[from_name]

        to_names.each do |to_name|
          to_pipeline = @pipelines[to_name]

          # Create a queue for communication
          queue = SizedQueue.new(1000)  # Reasonable buffer size

          # Connect pipelines
          from_pipeline.add_output_queue(to_name, queue)
          to_pipeline.input_queue = queue

          log_info "Connected pipeline #{from_name} -> #{to_name}"
        end
      end
    end

    def log_info(msg)
      Minigun.logger.info(msg)
    end
  end
end
