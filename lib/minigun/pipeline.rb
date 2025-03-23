# frozen_string_literal: true

require 'securerandom'
require 'concurrent'
require 'forwardable'
require 'logger'

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
              when Minigun::Stages::Processor, Minigun::Stages::Accumulator
                type
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
      # Add all stages from the task
      @task.pipeline.each do |stage_config|
        add_stage(stage_config[:type], stage_config[:name], stage_config[:options])
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
      @executor = PipelineExecutor.new(self)
      @executor.run

      # Run after_run hooks if task has hooks defined
      @task.run_hooks(:after_run, @context) if @task.respond_to?(:run_hooks)

      # Log pipeline completion
      @logger.info("[Minigun:#{@job_id}] Pipeline execution completed")

      self
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
        executor = PipelineExecutor.new(self)
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
        # Determine the appropriate stage class
        case stage_def[:type]
        when :processor
          Minigun::Stages::Processor
        when :accumulator
          Minigun::Stages::Accumulator
        else
          raise "Unknown stage type: #{stage_def[:type]}"
        end

        # Add the stage
        add_stage(stage_def[:type], stage_def[:name], stage_def[:options])
      end
    end

    # Validate the pipeline configuration
    def validate_pipeline
      # Collect all COW fork stages
      @stages.each do |stage_name, stage_info|
        next unless stage_info[:instance].respond_to?(:stage_type) && stage_info[:instance].stage_type == :cow

        # Find stage index in pipeline
        stage_names = @stages.keys
        index = stage_names.index(stage_name)

        # Check if any previous stage is an accumulator
        has_accumulator = false
        (0...index).each do |i|
          prev_stage = @stages[stage_names[i]]
          if prev_stage[:type] == :accumulator
            has_accumulator = true
            break
          end
        end

        # Warn and fall back to IPC if no accumulator
        unless has_accumulator
          warn "[Minigun:#{@job_id}] COW fork stage #{stage_name} must follow an accumulator stage - falling back to IPC"
          stage_info[:instance].stage_type = :ipc if stage_info[:instance].respond_to?(:stage_type=)
        end
      end
    end

    # Shutdown all stages and collect statistics
    def shutdown_stages
      # Shutdown all stages, collect statistics
      stage_stats = {}
      @stages.each do |stage_name, stage_info|
        # Call shutdown method if it exists
        next unless stage_info[:instance].respond_to?(:shutdown)

        stats = stage_info[:instance].shutdown
        stage_stats[stage_name] = stats

        # Log stats
        if stats.is_a?(Hash)
          stats_str = stats.map { |k, v| "#{k}: #{v}" }.join(', ')
          info("[Minigun:#{@job_id}] Stage #{stage_name} stats: #{stats_str}")
        end
      end

      # Return all stats
      stage_stats
    end
  end

  # Pipeline DSL executor used during pipeline definition
  class PipelineExecutor
    def initialize(pipeline)
      @pipeline = pipeline
    end

    # Define a producer stage
    def producer(name = :default, options = {}, &block)
      task = @pipeline.task

      # Add the stage to the task
      task.add_producer(name, options, &block)

      # Add to pipeline
      @pipeline.add_stage(Minigun::Stages::Processor, name, options)
    end

    # Define a processor stage
    def processor(name = :default, options = {}, &block)
      task = @pipeline.task

      # Add the stage to the task
      task.add_processor(name, options, &block)

      # Add to pipeline
      @pipeline.add_stage(Minigun::Stages::Processor, name, options)
    end

    # Define an accumulator stage
    def accumulator(name = :default, options = {}, &block)
      task = @pipeline.task

      # Add the stage to the task
      task.add_accumulator(name, options, &block)

      # Add to pipeline
      @pipeline.add_stage(Minigun::Stages::Accumulator, name, options)
    end

    # Define a consumer stage
    def consumer(name = :default, options = {}, &block)
      task = @pipeline.task

      # Add the stage to the task
      task.add_consumer(name, options, &block)

      # Add to pipeline
      @pipeline.add_stage(Minigun::Stages::Processor, name, options)
    end

    # Define a cow_fork consumer
    def cow_fork(name = :default, options = {}, &block)
      options = options.merge(fork: :cow)
      consumer(name, options, &block)
    end

    # Define an ipc_fork consumer
    def ipc_fork(name = :default, options = {}, &block)
      options = options.merge(fork: :ipc)
      consumer(name, options, &block)
    end

    def run
      # Run a simple input-output pipeline with a starting item
      run_pipeline_with_input(nil)
    end

    private

    def run_pipeline_with_input(input_item)
      # Track the first stage in the pipeline
      first_stage = @pipeline.stages.first

      # The first stage processes the input item
      first_stage&.process(input_item)
    end
  end
end
