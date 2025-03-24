# frozen_string_literal: true

module Minigun
  # Orchestrates the flow of items through stages
  class Pipeline
    extend Forwardable
    def_delegators :@logger, :info, :warn, :error, :debug

    attr_reader :context, :job_id, :stages, :task, :stage_connections

    def initialize(context, options = {})
      @context = context

      # Get the task from the context - more flexible approach
      @task = if options[:task]
                options[:task]
              elsif context.is_a?(Minigun::Task)
                context
              elsif context.class.respond_to?(:_minigun_task)
                context.class._minigun_task
              elsif context.is_a?(Module) && context.respond_to?(:_minigun_task)
                context._minigun_task
              else
                # For custom contexts that are not tasks or modules with DSL
                # we'll use the task from options or create a simple one
                options[:task] || Minigun::Task.new
              end

      # Generate a unique ID for this pipeline
      @job_id = options[:job_id] || SecureRandom.hex(4)

      # Get pipeline configuration
      @is_custom = options[:custom] || false

      # Initialize task execution options
      @max_threads = options[:max_threads] || @task.config[:max_threads]
      @max_processes = options[:max_processes] || @task.config[:max_processes]
      @max_retries = options[:max_retries] || @task.config[:max_retries]
      @logger = options[:logger] || @task.config[:logger]
      @debug = options[:debug] || false

      # Initialize pipeline components
      @stages = []
      @stage_connections = {}
      @executor = nil

      # Build pipeline
      return unless @is_custom || false

      build_pipeline
    end

    # Add a stage to the pipeline
    def add_stage(type, name, options = {})
      # Create the appropriate stage class
      klass = case type
              when :processor
                Minigun::Stages::Processor
              when :accumulator
                Minigun::Stages::Accumulator
              when Class
                # If a class is passed directly
                type
              when Symbol
                # Try to find the class by name
                if Minigun::Stages.const_defined?(type.to_s.capitalize)
                  Minigun::Stages.const_get(type.to_s.capitalize)
                else
                  raise "Unknown stage type: #{type}"
                end
              else
                raise "Unknown stage type: #{type}"
              end

      stage = klass.new(name, self, options)
      @stages << stage
      stage
    end

    # Connect stages in the pipeline
    def connect_stages(stage_connections = nil)
      # Use provided connections or initialize from task
      if stage_connections
        @stage_connections = stage_connections
      elsif @task.connections.any?
        @stage_connections = @task.connections
      else
        # If no connections provided, create default linear pipeline
        # where each stage connects to the next one
        @stages.each_with_index do |stage, i|
          next unless i < @stages.size - 1

          next_stage = @stages[i + 1]
          @stage_connections[stage.name] ||= []
          @stage_connections[stage.name] << next_stage.name
        end
      end

      self
    end

    # Build the pipeline based on task configuration
    def build_pipeline
      if @task.pipeline_definition
        # If we have a pipeline definition block, execute it
        @executor = PipelineDSL.new(self)
        @executor.instance_eval(&@task.pipeline_definition)
      else
        # Add all stages from the task
        @task.pipeline.each do |stage_config|
          add_stage(stage_config[:type], stage_config[:name], stage_config[:options])
        end
      end

      # Connect stages
      connect_stages

      self
    end

    # Run the built pipeline
    def run
      # Run before_run hooks if task has hooks defined
      @task.run_hooks(:before_run, @context) if @task.respond_to?(:run_hooks)

      # Log pipeline startup
      @logger.info("[Minigun:#{@job_id}] Starting pipeline execution")

      # Create and initialize the executor
      @executor = PipelineDSL.new(self)
      
      # Set fork_mode flag to all stages if needed
      if @task.config && @task.config[:fork_mode] == :never
        # When fork_mode is :never, ensure all stages know about it
        @stages.each do |stage|
          stage.instance_variable_set(:@fork_mode, :never) if stage.respond_to?(:instance_variable_set)
        end
      end
      
      # Run each stage
      @stages.each do |stage|
        stage.run if stage.respond_to?(:run)
      end
      
      # Run after_run hooks if task has hooks defined
      @task.run_hooks(:after_run, @context) if @task.respond_to?(:run_hooks)

      # Log pipeline completion
      @logger.info("[Minigun:#{@job_id}] Pipeline execution completed")

      self
    end
    
    # Shutdown the pipeline and all stages
    def shutdown
      @logger.info("[Minigun:#{@job_id}] Shutting down pipeline")
      
      # Shutdown all stages in reverse order
      stats = {}
      @stages.reverse_each do |stage|
        if stage.respond_to?(:shutdown)
          result = stage.shutdown
          stats[stage.name] = result
          
          # Log the stage stats
          if result.is_a?(Hash)
            stats_str = result.map { |k, v| "#{k}: #{v}" }.join(', ')
            @logger.info("[Minigun:#{@job_id}][Stage:#{stage.name}] Stats: #{stats_str}")
          end
        end
      end
      
      stats
    end

    # Print a log message if debug is enabled
    def debug(message)
      @logger.debug(message) if @debug
    end

    # Get the queue subscriptions for a stage
    def queue_subscriptions(stage_name)
      return [:default] unless @task.queue_subscriptions && @task.queue_subscriptions[stage_name.to_sym]

      @task.queue_subscriptions[stage_name.to_sym]
    end

    # Find downstream stages connected to a given stage
    def downstream_stages(stage_name)
      return [] unless @stage_connections && @stage_connections[stage_name]

      # Get connected stage names
      stage_names = @stage_connections[stage_name]

      # Find stage objects by name
      stage_names.filter_map { |name| @stages.find { |s| s.name == name } }
    end

    private

    # Build pipeline from task definition
    def build_pipeline_from_task_definition
      # If we have a pipeline definition block, execute it
      if @task.pipeline_definition
        # Use an executor to build the pipeline
        executor = PipelineDSL.new(self)
        executor.instance_eval(&@task.pipeline_definition)
      else
        # Otherwise use the pipeline array
        build_pipeline_from_stages
      end
    end

    # Build the pipeline from the stages array
    def build_pipeline_from_stages
      # For each stage in the pipeline, add it to the pipeline
      @task.pipeline.each do |stage_def|
        add_stage(stage_def[:type], stage_def[:name], stage_def[:options])
      end
    end

    # Validate the pipeline configuration
    def validate_pipeline
      # Collect all COW fork stages
      @stages.each do |stage|
        next unless stage.respond_to?(:stage_type) && stage.stage_type == :cow

        # Find stage index in pipeline
        index = @stages.index(stage)

        # Check if any previous stage is a accumulator stage
        has_accumulator = false
        (0...index).each do |i|
          prev_stage = @stages[i]
          if prev_stage.is_a?(Minigun::Stages::Accumulator)
            has_accumulator = true
            break
          end
        end

        # Warn and fall back to IPC if no accumulator stage
        unless has_accumulator
          warn "[Minigun:#{@job_id}] COW fork stage #{stage.name} must follow an accumulator stage - falling back to IPC"
          stage.stage_type = :ipc if stage.respond_to?(:stage_type=)
        end
      end
    end
  end
end
