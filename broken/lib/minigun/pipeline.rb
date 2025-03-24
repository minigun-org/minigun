# frozen_string_literal: true

module Minigun
  # Orchestrates the flow of items through stages
  class Pipeline
    extend Forwardable
    include Minigun::HooksMixin
    
    # Register standard Minigun hook points
    register_hook_points :run, :stage
    
    def_delegators :@logger, :info, :warn, :error, :debug

    attr_reader :context, :job_id, :stages, :task, :stage_connections

    def initialize(task, context, options = {})
      @task = task
      @context = context
      @job_id = options[:job_id] || SecureRandom.hex(4)

      # Set up logger
      @logger = Logger.new($stdout)
      @logger.level = options[:log_level] || Logger::INFO
      @debug = options[:debug] || false

      # Initialize stages array
      @stages = []

      # Initialize stage connections
      @stage_connections = {}

      # Initialize queue state
      @queues = {}

      # Initialize status flags
      @running = false
      @terminating = false
    end

    # Add a stage to the pipeline
    def add_stage(stage)
      # Add to our stages array
      @stages << stage
      
      # Return the stage for chaining
      stage
    end

    # Connect stages together
    def connect_stages(stage_connections = nil)
      # Use provided connections or initialize from task
      if stage_connections
        @stage_connections = stage_connections
      elsif @task.connections&.any?
        @stage_connections = @task.connections.dup
      else
        # Create linear connections (default)
        @stage_connections = build_linear_connections
      end

      # Connect stages based on the connections map
      @stages.each do |stage|
        # Get downstream connections
        downstream = downstream_stages(stage.name)

        # Connect to downstream stages
        downstream.each do |ds_name|
          # Find the referenced stage
          target_stage = @stages.find { |s| s.name.to_sym == ds_name.to_sym }
          
          # Connect if we found it
          if target_stage
            stage.add_output(target_stage)
          else
            warn "Stage #{ds_name} referenced in connections not found"
          end
        end

        # Set up queue subscriptions
        stage.queues = queue_subscriptions(stage.name)
      end

      self
    end

    # Build the pipeline from the task definitions
    def build_pipeline
      # Skip if already built
      return self if @stages.any?

      # Build the pipeline
      if @task.pipeline_definition
        build_pipeline_from_task_definition
      elsif @task.pipeline.any?
        build_pipeline_from_stages
      else
        raise 'No pipeline definition found'
      end

      # Connect the stages
      connect_stages

      # Validate the pipeline
      validate_pipeline

      # Return the pipeline
      self
    end

    # Run the pipeline
    def run
      # Run the pipeline with hooks
      # This will now use run_hook instead of run_hooks
      @task.run_hook :run, @context do
        # Build the pipeline if not already built
        build_pipeline if @stages.empty?

        # Set running flag
        @running = true

        # Start all stages
        @stages.each(&:start)

        # Wait for all stages to finish
        @stages.each(&:join)

        # Set running flag to false
        @running = false

        # Return the context
        @context
      end
    end

    # Shutdown the pipeline
    def shutdown
      @logger.info("[Minigun:#{@job_id}] Shutting down pipeline")

      # Signal termination
      @terminating = true

      # Stop all stages
      @stages.each(&:stop)
    end

    # Get a stage by name
    def stage(name)
      @stages.find { |s| s.name.to_sym == name.to_sym }
    end

    # Check if the pipeline is still running
    def running?
      @running
    end

    # Check if the pipeline is terminating
    def terminating?
      @terminating
    end

    # Debug output if debug mode is enabled
    def debug(message)
      @logger.debug(message) if @debug
    end

    # Get the queue subscriptions for a stage
    def queue_subscriptions(stage_name)
      return [:default] unless @task.queue_subscriptions && @task.queue_subscriptions[stage_name.to_sym]

      @task.queue_subscriptions[stage_name.to_sym]
    end

    # Get downstream stages for a given stage
    def downstream_stages(stage_name)
      return [] unless @stage_connections && @stage_connections[stage_name]

      if @stage_connections[stage_name].is_a?(Array)
        @stage_connections[stage_name]
      else
        [@stage_connections[stage_name]]
      end
    end

    private

    # Build a pipeline from a direct definition block
    def build_pipeline_from_task_definition
      # If we have a pipeline definition block, execute it
      if @task.pipeline_definition
        # Call the pipeline definition block with this pipeline
        @task.pipeline_definition.call(self)
      end
    end

    # Build a pipeline from the stages array
    def build_pipeline_from_stages
      # For each stage in the pipeline, add it to the pipeline
      @task.stage_blocks.each do |name, config|
        # TODO: Create and add stage
      end
    end

    # Validate the pipeline configuration
    def validate_pipeline
      # Collect all COW fork stages
      @stages.each do |stage|
        # Check if the stage is a CowFork
        if stage.is_a?(Minigun::Stages::CowFork)
          # Ensure it has a predecessor that is an Accumulator
          unless stage.inputs.any? { |s| s.is_a?(Minigun::Stages::Accumulator) }
            warn "COW fork stage '#{stage.name}' should have an Accumulator as input for best performance"
          end
        end
      end
    end

    # Build linear connections between stages
    def build_linear_connections
      connections = {}
      
      # For each stage, connect to the next stage
      @stages.each_with_index do |stage, index|
        # Skip the last stage
        next if index >= @stages.size - 1
        
        # Get the next stage
        next_stage = @stages[index + 1]
        
        # Create a connection
        connections[stage.name] = [next_stage.name]
      end
      
      connections
    end
  end
end
