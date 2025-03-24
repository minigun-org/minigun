# frozen_string_literal: true

module Minigun
  # The Task class manages the configuration and execution of Minigun tasks
  class Task
    attr_reader :hooks, :pipeline, :connections, :queue_subscriptions
    attr_accessor :config, :stage_blocks, :pipeline_definition, :accumulated_items

    def initialize
      @config = {
        max_threads: 5,
        max_processes: 2,
        max_retries: 3,
        batch_size: 100,
        accumulator_max_queue: 2000,
        accumulator_max_all: 4000,
        accumulator_check_interval: 100,
        logger: Logger.new($stdout),
        fork_mode: :auto, # :auto, :always, :never
        consumer_type: :ipc # :ipc or :cow
      }

      # Initialize hook arrays
      @hooks = {
        before_run: [],
        after_run: [],
        before_fork: [],
        after_fork: [],
        after_producer_finished: [],
        after_consumer_finished: []
      }

      # Initialize stage block maps - all stage variants share a common block structure
      @stage_blocks = {}

      # Initialize pipeline
      @pipeline = []

      # Initialize pipeline definition
      @pipeline_definition = nil

      # Initialize stage connections
      @connections = {}

      # Initialize queue subscriptions
      @queue_subscriptions = {}
      
      # Initialize accumulated items for testing
      @accumulated_items = []
    end
    
    # Generic method to add a stage of any type
    def add_stage(type, name = :default, options = {}, &block)
      # Process connection options
      options = process_connection_options(name, options)
      
      # Store the block for this stage
      @stage_blocks[name.to_sym] = block if block_given?
      
      # Apply stage-specific configurations
      apply_stage_options(type, options)
      
      # Record stage in pipeline
      @pipeline << {
        type: type,
        name: name,
        options: options
      }
      
      # For backward compatibility with the cow_fork feature
      validate_stage_placement(type, name) if type == :cow_fork
    end

    # Process a connection option to determine where to send output
    def process_connection_options(name, options)
      # Extract connection options
      from = options.delete(:from)
      to = options.delete(:to)
      queues = options.delete(:queues) || [:default]

      # Record "from" connection if specified
      if from
        source_names = from.is_a?(Array) ? from : [from]
        source_names.each do |source_name|
          @connections[source_name] ||= []
          @connections[source_name] << name unless @connections[source_name].include?(name)
        end
      end

      # Record "to" connection if specified
      if to
        target_names = to.is_a?(Array) ? to : [to]
        @connections[name] = target_names
      end

      # Record queue subscriptions
      @queue_subscriptions[name] = queues.map(&:to_sym)

      # Return the processed options
      options
    end

    # Define the producer block that generates items
    def add_producer(name = :default, options = {}, &block)
      add_stage(:processor, name, options, &block)
    end

    # Define a processor block that transforms items
    def add_processor(name = :default, options = {}, &block)
      add_stage(:processor, name, options, &block)
    end

    # Define a specialized accumulator stage
    def add_accumulator(name = :default, options = {}, &block)
      add_stage(:accumulator, name, options, &block)
    end

    # Define a consumer stage
    def add_consumer(name = :default, options = {}, &block)
      # Handle fork options
      if options[:fork] == :cow
        add_stage(:cow_fork, name, options, &block)
      else
        add_stage(:processor, name, options, &block)
      end
    end

    # Define hooks with options similar to ActionController
    def add_hook(name, options = {}, &block)
      hook_config = { only: [], except: [], if: [], unless: [] }
      hook_config.merge!(options)
      hook_config[:block] = block if block_given?

      @hooks[name] ||= []
      @hooks[name] << hook_config
    end

    # Run the defined task for the given context
    def run(context)
      validate_configuration!

      # If a custom pipeline is defined, use it
      if @pipeline_definition || @pipeline.any?
        run_custom_pipeline(context)
      else
        # Otherwise, use the simple producer-consumer pattern
        run_simple_pipeline(context)
      end
    end

    # Run all hooks of a specific type
    def run_hooks(type, context, *args)
      return unless @hooks[type]

      @hooks[type].each do |hook|
        # Check conditions for running the hook
        next if hook[:only].is_a?(Array) && hook[:only].any? && !hook[:only].include?(context.class.name)
        next if hook[:except].is_a?(Array) && hook[:except].any? && hook[:except].include?(context.class.name)

        # No conditions means always run
        if_conditions = hook[:if]
        unless_conditions = hook[:unless]

        # If conditions must all pass
        if if_conditions
          if_conditions = [if_conditions].flatten
          next unless if_conditions.all? do |condition|
            if condition.is_a?(Proc)
              context.instance_exec(*args, &condition)
            else
              condition
            end
          end
        end

        # Unless conditions must all fail
        if unless_conditions
          unless_conditions = [unless_conditions].flatten
          next if unless_conditions.any? do |condition|
            if condition.is_a?(Proc)
              context.instance_exec(*args, &condition)
            else
              condition
            end
          end
        end

        # Execute the hook block
        context.instance_exec(*args, &hook[:block]) if hook[:block]
      end
    end

    private
    
    # Apply stage-specific options to the provided options hash
    def apply_stage_options(type, options)
      case type
      when :accumulator
        # Stage with queueing capability
        options[:batch_size] ||= @config[:batch_size]
        options[:flush_interval] ||= @config[:accumulator_check_interval] / 20.0
        options[:max_batch_size] ||= @config[:accumulator_max_queue]
      when :consumer, :processor
        # Basic processing options
        options[:max_threads] ||= @config[:max_threads]
        options[:threads] ||= options[:max_threads]
        options[:max_retries] ||= @config[:max_retries]
      when :cow_fork
        # COW fork specific options
        options[:fork] = :cow
        options[:type] = :cow
        options[:max_processes] ||= @config[:max_processes]
        options[:processes] ||= options[:max_processes]
      end
    end

    # Validate that a consumer stage comes after a queueing stage when needed
    def validate_stage_placement(type, name)
      # Only validate cow_fork stages currently
      return unless type == :cow_fork

      # Find this stage's index
      stage_index = @pipeline.find_index { |s| s[:name] == name }
      return unless stage_index

      # Check if there's an explicit "from" connection to a queueing stage
      if @connections.any?
        # Look for sources that point to this consumer
        has_queueing_source = false
        @connections.each do |source_name, targets|
          next unless targets.is_a?(Array) ? targets.include?(name) : targets == name

          # Check if source is a queueing stage
          source_index = @pipeline.find_index { |s| s[:name] == source_name }
          if source_index && %i[accumulator].include?(@pipeline[source_index][:type])
            has_queueing_source = true
            break
          end
        end

        # If no queueing source found and we're using a COW fork, warn
        unless has_queueing_source
          warn "COW fork stage #{name} should follow a queueing stage for efficiency"
        end
      end
    end

    # Validate configuration settings
    def validate_configuration!
      raise "No stages defined in pipeline" if @pipeline.empty? && !@pipeline_definition
    end

    # Run a custom pipeline from the definition or pipeline array
    def run_custom_pipeline(context)
      # Create a pipeline instance
      pipeline = Minigun::Pipeline.new(context, job_id: SecureRandom.hex(4), custom: true)
      pipeline.build_pipeline
      pipeline.run
      pipeline.shutdown
    end

    # Run a simple producer-consumer pattern
    def run_simple_pipeline(context)
      # Create a runner instance
      runner = Minigun::Runner.new(context)
      runner.run
    end
  end
end
