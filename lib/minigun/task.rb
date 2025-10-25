# frozen_string_literal: true

module Minigun
  # Task orchestrates one or more pipelines
  # Supports both single-pipeline (implicit) and multi-pipeline modes
  class Task
    attr_reader :config, :pipelines, :pipeline_dag, :implicit_pipeline

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

      # Implicit pipeline for single-pipeline mode (backward compatibility)
      @implicit_pipeline = Pipeline.new(:default, @config)

      # Named pipelines for multi-pipeline mode
      @pipelines = {}  # { pipeline_name => Pipeline }
      @pipeline_dag = DAG.new  # Pipeline-level routing
    end

    # Set config value (applies to all pipelines)
    def set_config(key, value)
      @config[key] = value

      # Update implicit pipeline config
      @implicit_pipeline.config[key] = value

      # Update all named pipelines
      @pipelines.each_value do |pipeline|
        pipeline.config[key] = value
      end
    end

    # Add a stage to the implicit pipeline (for backward compatibility)
    def add_stage(type, stage_name, options = {}, &block)
      @implicit_pipeline.add_stage(type, stage_name, options, &block)
    end

    # Add a hook to the implicit pipeline (for backward compatibility)
    def add_hook(type, &block)
      @implicit_pipeline.add_hook(type, &block)
    end

    # Add a nested pipeline as a stage within the implicit pipeline
    def add_nested_pipeline(name, options = {}, &block)
      # Create a PipelineStage and configure it
      pipeline_stage = PipelineStage.new(name: name, options: options)

      # Create the actual Pipeline instance for this nested pipeline
      nested_pipeline = Pipeline.new(name, @config)
      pipeline_stage.pipeline = nested_pipeline

      # Add stages to the nested pipeline via block
      if block_given?
        dsl = Minigun::DSL::PipelineDSL.new(nested_pipeline)
        dsl.instance_eval(&block)
      end

      # Add the pipeline stage to the implicit pipeline
      @implicit_pipeline.stages[name] = pipeline_stage
      @implicit_pipeline.instance_variable_get(:@stage_order) << name
      @implicit_pipeline.dag.add_node(name)

      # Extract routing if specified
      to_targets = options[:to]
      if to_targets
        Array(to_targets).each { |target| @implicit_pipeline.dag.add_edge(name, target) }
      end

      pipeline_stage
    end

    # Define a named pipeline with routing
    def define_pipeline(name, options = {}, &block)
      # Create or get named pipeline
      pipeline = @pipelines[name] ||= Pipeline.new(name, @config)
      @pipeline_dag.add_node(name)

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

    # Run the task with full lifecycle management (signal handling, job ID, stats)
    # Use this for production execution
    def run(context)
      runner = Minigun::Runner.new(self, context)
      runner.run
    end

    # Direct pipeline execution without Runner overhead
    # Use this for testing or embedding in other systems
    def perform(context)
      if @pipelines.empty?
        # Single-pipeline mode: run implicit pipeline
        @implicit_pipeline.run(context)
      else
        # Multi-pipeline mode: run all named pipelines
        run_multi_pipeline(context)
      end
    end

    # Access stages for backward compatibility
    def stages
      @implicit_pipeline.stages
    end

    # Access hooks for backward compatibility
    def hooks
      @implicit_pipeline.hooks
    end

    # Access DAG for backward compatibility (stage-level DAG)
    def dag
      @implicit_pipeline.dag
    end

    private

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
