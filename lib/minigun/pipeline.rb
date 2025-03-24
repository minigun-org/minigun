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
    def add_stage(name, type, options = {}, &block)
      # Create stage based on type
      stage = case type.to_sym
             when :processor, :consumer, :producer
               Minigun::Stages::Processor.new(name, options)
             when :accumulator
               Minigun::Stages::Accumulator.new(name, options)
             when :double
               # Test double stage - just stores items
               Minigun::Stages::TestDouble.new(name, options)
             else
               raise ArgumentError, "Unknown stage type: #{type}"
             end

      # Set the block if provided
      stage.block = block if block

      # Add to stages array
      @stages << stage

      # Return the stage
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
      validate_pipeline!

      # Run before_run hooks
      @task.run_hooks(:before_run, @context)

      begin
        # Process remaining stages
        processor_stages = @stages.reject { |s| s.is_a?(Minigun::Stages::Emitter) }
        processor_stages.each { |stage| stage.run(@context) }
      ensure
        # Run after_run hooks
        @task.run_hooks(:after_run, @context)
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
      @stages.clear
      
      @task.pipeline.each do |stage_config|
        name = stage_config[:name]
        type = stage_config[:type]
        options = stage_config[:options] || {}
        block = stage_config[:block]
        
        # Add from/to if they exist
        options[:from] = stage_config[:from] if stage_config[:from]
        options[:to] = stage_config[:to] if stage_config[:to]
        
        # Add the stage
        add_stage(name, type, options, &block)
      end

      # Connect stages based on from/to relationships
      connect_stages
      
      self
    end

    # Validate the pipeline configuration
    def validate_pipeline!
      # Ensure we have at least one stage
      raise Minigun::Error, 'Pipeline must have at least one stage' if @stages.empty?

      # Validate stage connections
      @stages.each do |stage|
        # Ensure non-emitter stages have at least one source
        if stage.sources.empty?
          raise Minigun::Error, "Stage #{stage.name} has no source stages"
        end
      end

      # For COW processor, ensure there's an accumulator before it
      if @task.config[:fork_type] == :cow
        @stages.each do |stage|
          if stage.is_a?(Minigun::Stages::Processor) && stage.options[:forking] == :cow
            unless stage.sources.any? { |s| s.is_a?(Minigun::Stages::Accumulator) }
              raise Minigun::Error, "COW processor stage #{stage.name} must have an accumulator as input"
            end
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
