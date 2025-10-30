# frozen_string_literal: true

module Minigun
  # Task orchestrates one or more pipelines
  # Supports both single-pipeline (implicit) and multi-pipeline modes
  class Task
    attr_reader :config, :root_pipeline, :registry

    def initialize(config: nil, root_pipeline: nil)
      @config = config || {
        max_threads: 5,
        max_processes: 2,
        max_retries: 3,
        accumulator_max_single: 2000,
        accumulator_max_all: 4000,
        accumulator_check_interval: 100,
        use_ipc: false
      }

      # Unified registry for all stage lookups (ID and name-based)
      @registry = NameRegistry.new(self)

      # Root pipeline - all stages and nested pipelines live here
      @root_pipeline = root_pipeline || Pipeline.new(self, :default, @config)
      # Ensure root pipeline's task reference points to this task
      @root_pipeline.task = self
    end

    # Find a stage by ID or name
    # For ID lookups, this is fast and unambiguous
    # For name lookups, uses root pipeline as context
    def find_stage(identifier, from_pipeline: nil)
      from_pipeline ||= @root_pipeline
      @registry.find(identifier, from_pipeline: from_pipeline)
    end

    # Set config value (applies to all pipelines)
    def set_config(key, value)
      @config[key] = value

      # Update root pipeline config
      @root_pipeline.config[key] = value

      # Update all nested pipelines
      pipelines.each_value do |pipeline|
        pipeline.config[key] = value
      end
    end

    # Get all named pipelines (composite stages in root_pipeline)
    def pipelines
      @root_pipeline.stages.select { |_id, stage| stage.run_mode == :composite }
                    .transform_values(&:pipeline)
    end

    # Get the DAG for pipeline-level routing
    def pipeline_dag
      @root_pipeline.dag
    end

    # Add a stage to the implicit pipeline (for backward compatibility)
    def add_stage(type, stage_name, options = {}, &)
      @root_pipeline.add_stage(type, stage_name, options, &)
    end

    # Add a hook to the implicit pipeline (for backward compatibility)
    def add_hook(type, &)
      @root_pipeline.add_hook(type, &)
    end

    # Add a nested pipeline as a stage within the implicit pipeline
    def add_nested_pipeline(name, options = {}, &)
      # Create a PipelineStage in the root pipeline
      pipeline_stage = PipelineStage.new(@root_pipeline, name, nil, options)

      # Create the actual Pipeline instance for this nested pipeline
      nested_pipeline = Pipeline.new(self, name, @config)
      pipeline_stage.nested_pipeline = nested_pipeline

      # Add stages to the nested pipeline via block
      if block_given?
        dsl = Minigun::DSL::PipelineDSL.new(nested_pipeline)
        dsl.instance_eval(&)
      end

      # Add the pipeline stage to the implicit pipeline by ID (stage already registered in Task)
      pipeline_stage_id = pipeline_stage.id
      @root_pipeline.stages[pipeline_stage_id] = pipeline_stage
      @root_pipeline.stage_order << pipeline_stage_id
      @root_pipeline.dag.add_node(pipeline_stage_id)

      # Extract routing if specified (resolve names to IDs)
      to_targets = options[:to]
      if to_targets
        Array(to_targets).each do |target|
          target_id = @root_pipeline.resolve_stage_identifier(target)
          @root_pipeline.dag.add_edge(pipeline_stage_id, target_id) if target_id
        end
      end

      pipeline_stage
    end

    # Define a named pipeline with routing
    # Pipelines are just PipelineStage objects in root_pipeline
    def define_pipeline(name, options = {})
      # Check if already exists by name (resolve to ID)
      existing_stage = find_stage(name)
      if existing_stage && existing_stage.run_mode == :composite
        pipeline_stage = existing_stage
        pipeline = pipeline_stage.nested_pipeline
        pipeline_stage_id = pipeline_stage.id
      else
        if existing_stage && existing_stage.run_mode != :composite
          raise Minigun::Error, "Stage #{name} already exists as a non-composite stage"
        end

        # Create new PipelineStage in root_pipeline
        pipeline_stage = PipelineStage.new(@root_pipeline, name, nil, options)
        pipeline = Pipeline.new(self, name, @config)
        pipeline_stage.nested_pipeline = pipeline
        pipeline_stage_id = pipeline_stage.id

        @root_pipeline.stages[pipeline_stage_id] = pipeline_stage
        @root_pipeline.stage_order << pipeline_stage_id
        @root_pipeline.dag.add_node(pipeline_stage_id)
      end

      # Handle routing in root_pipeline DAG (resolve names to IDs)
      # Use same forward reference mechanism as add_stage
      to_targets = options[:to]
      if to_targets
        Array(to_targets).each do |target|
          target_id = @root_pipeline.resolve_stage_identifier(target)
          if target_id
            # Target exists - add edge with ID immediately
            @root_pipeline.dag.add_edge(pipeline_stage_id, target_id)
          else
            # Forward reference - store for later resolution during build_dag_routing!
            @root_pipeline.instance_variable_get(:@pending_edges) << [:to, pipeline_stage_id, target]
          end
        end
      end

      from_sources = options[:from]
      if from_sources
        Array(from_sources).each do |source|
          source_id = @root_pipeline.resolve_stage_identifier(source)
          if source_id
            # Source exists - add edge with ID immediately
            @root_pipeline.dag.add_edge(source_id, pipeline_stage_id)
          else
            # Forward reference - store for later resolution during build_dag_routing!
            @root_pipeline.instance_variable_get(:@pending_edges) << [:from, source, pipeline_stage_id]
          end
        end
      end

      # Execute block in context of pipeline definition
      yield pipeline if block_given?

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
      # Just run the root pipeline - it handles all stages transparently
      @root_pipeline.run(context)
    end

    # Access stages for backward compatibility
    def stages
      @root_pipeline.stages
    end

    # Access hooks for backward compatibility
    def hooks
      @root_pipeline.hooks
    end

    # Access DAG for backward compatibility (stage-level DAG)
    def dag
      @root_pipeline.dag
    end
  end
end
