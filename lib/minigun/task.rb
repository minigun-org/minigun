# frozen_string_literal: true

module Minigun
  # The Task class manages the configuration and execution of Minigun tasks
  class Task
    attr_reader :hooks, :pipeline, :connections, :queue_subscriptions
    attr_accessor :config, :stage_blocks, :pipeline_definition

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
      # Process connection options
      options = process_connection_options(name, options)

      # Store the block
      @stage_blocks[name] = block if block_given?

      # Record stage in pipeline
      @pipeline << {
        type: :processor, # Use processor type with producer role
        name: name,
        options: options
      }
    end

    # Define a processor block that transforms items
    def add_processor(name = :default, options = {}, &block)
      # Process connection options
      options = process_connection_options(name, options)

      # Store the processor block
      @stage_blocks[name] = block if block_given?

      # Record stage in pipeline
      @pipeline << {
        type: :processor,
        name: name,
        options: options
      }
    end

    # Define a specialized accumulator stage
    def add_accumulator(name = :default, options = {}, &block)
      # Process connection options
      options = process_connection_options(name, options)

      # Extract accumulator-specific options with appropriate defaults
      options[:max_queue] = options.delete(:max_queue) || @config[:accumulator_max_queue]
      options[:max_all] = options.delete(:max_all) || @config[:accumulator_max_all]
      options[:check_interval] = options.delete(:check_interval) || @config[:accumulator_check_interval]

      @stage_blocks[name] = block if block_given?

      # Record stage in pipeline
      @pipeline << {
        type: :accumulator,
        name: name,
        options: options
      }
    end

    # Define a consumer stage
    def add_consumer(name = :default, options = {}, &block)
      # Process connection options
      options = process_connection_options(name, options)

      # Extract consumer-specific options with appropriate defaults
      # Support fork: as an alternative to type:
      fork_type = options.delete(:fork)
      options[:type] = fork_type || options.delete(:type) || @config[:consumer_type]
      options[:max_processes] = options.delete(:max_processes) || @config[:max_processes]
      options[:max_threads] = options.delete(:max_threads) || @config[:max_threads]
      options[:max_retries] = options.delete(:max_retries) || @config[:max_retries]
      options[:batch_size] = options.delete(:batch_size) || @config[:batch_size]
      options[:threads] = options.delete(:threads) || options[:max_threads]
      options[:processes] = options.delete(:processes) || options[:max_processes]

      # Store the consumer block
      @stage_blocks[name] = block if block_given?

      # Record stage in pipeline - use processor type for all stages
      @pipeline << {
        type: :processor, # All stages are now processors
        name: name,
        options: options
      }

      # If this is a COW consumer type, validate placement
      validate_consumer_placement(:cow, name) if options[:type] == :cow
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

    # Validate that a consumer stage comes after an accumulator when needed
    def validate_consumer_placement(consumer_type, name)
      # Only validate cow consumers currently
      return unless consumer_type == :cow

      # Find this stage's index
      consumer_index = @pipeline.find_index { |s| s[:name] == name && s[:type] == :consumer }
      return unless consumer_index

      # Check if there's an explicit "from" connection to an accumulator
      if @connections.any?
        # Look for sources that point to this consumer
        has_accumulator_source = false
        @connections.each do |source_name, targets|
          next unless targets.is_a?(Array) ? targets.include?(name) : targets == name

          # Check if source is an accumulator
          source_index = @pipeline.find_index { |s| s[:name] == source_name }
          if source_index && @pipeline[source_index][:type] == :accumulator
            has_accumulator_source = true
            break
          end
        end

        unless has_accumulator_source
          # For implicit connections, check previous stage
          raise Minigun::Error, "Cow consumer/fork stage '#{name}' must follow an accumulator stage" unless consumer_index > 0

          prev_stage = @pipeline[consumer_index - 1]
          raise Minigun::Error, "Cow consumer/fork stage '#{name}' must follow an accumulator stage" unless prev_stage[:type] == :accumulator
        end
      else
        # For sequential pipelines, check previous stage
        raise Minigun::Error, "Cow consumer/fork stage '#{name}' must be preceded by an accumulator stage" unless consumer_index > 0

        prev_stage = @pipeline[consumer_index - 1]
        raise Minigun::Error, "Cow consumer/fork stage '#{name}' must follow an accumulator stage" unless prev_stage[:type] == :accumulator
      end
    end

    def validate_configuration!
      # Basic validation logic
      # For COW consumer, ensure there's an accumulator before it
      if @config[:consumer_type] == :cow &&
         @pipeline.any? { |s| s[:type] == :consumer } &&
         @pipeline.none? { |s| s[:type] == :accumulator }

        raise Minigun::Error, 'COW consumer requires an accumulator stage before it'
      end
    end

    def run_simple_pipeline(context)
      # Let the Runner handle this simple case
      runner = Minigun::Runner.new(context)
      runner.run
    end

    def run_custom_pipeline(context)
      # Create and run a custom pipeline
      pipeline = Minigun::Pipeline.new(context, custom: true)
      pipeline.run
    end
  end
end
