# frozen_string_literal: true

require 'logger'

module Minigun
  # The Task module provides a DSL for defining Minigun tasks
  module Task
    def self.included(base)
      base.extend(ClassMethods)
      base.class_eval do
        @_minigun_config = {
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
        @_minigun_hooks = {
          before_run: [],
          after_run: [],
          before_fork: [],
          after_fork: [],
          after_producer_finished: [],
          after_consumer_finished: []
        }

        # Initialize stage block maps - all processor variants share a common block structure
        @_minigun_processor_blocks = {}
        @_minigun_accumulator_blocks = {}

        # Initialize pipeline
        @_minigun_pipeline = []

        # Initialize pipeline definition
        @_minigun_pipeline_definition = nil

        # Initialize stage connections
        @_minigun_connections = {}

        # Initialize queue subscriptions
        @_minigun_queue_subscriptions = {}

        # Define class accessor methods for these instance variables
        class << self
          attr_reader :_minigun_config,
                      :_minigun_processor_blocks,
                      :_minigun_accumulator_blocks,
                      :_minigun_hooks,
                      :_minigun_pipeline,
                      :_minigun_pipeline_definition,
                      :_minigun_connections,
                      :_minigun_queue_subscriptions

          # For backward compatibility with code that expects separate block collections
          def _minigun_producer_blocks
            _minigun_processor_blocks
          end

          # For compatibility with older code
          def _minigun_producer_block
            _minigun_processor_blocks[:default]
          end

          # For backward compatibility with code that expects separate block collections
          def _minigun_consumer_blocks
            _minigun_processor_blocks
          end
        end
      end
    end

    module ClassMethods
      # Set maximum number of threads per consumer process
      def max_threads(value)
        @_minigun_config[:max_threads] = value
      end

      # Set maximum number of consumer processes to fork
      def max_processes(value)
        @_minigun_config[:max_processes] = value
      end

      # Alias for max_processes for more intuitive API
      def max_consumer_forks(value)
        max_processes(value)
      end

      # Set maximum retry attempts for failed item processing
      def max_retries(value)
        @_minigun_config[:max_retries] = value
      end

      # Set batch size for consumer threads
      def batch_size(value)
        @_minigun_config[:batch_size] = value
      end

      # Set maximum items in a single queue before forking
      def accumulator_max_queue(value)
        @_minigun_config[:accumulator_max_queue] = value
      end

      # Set maximum items across all queues before forking
      def accumulator_max_all(value)
        @_minigun_config[:accumulator_max_all] = value
      end

      # Set interval for checking accumulator queues
      def accumulator_check_interval(value)
        @_minigun_config[:accumulator_check_interval] = value
      end

      # Set forking mode (:auto, :always, :never)
      def fork_mode(mode)
        raise Minigun::Error, 'Fork mode must be :auto, :always, or :never' unless %i[auto always never].include?(mode)

        @_minigun_config[:fork_mode] = mode
      end

      # Set consumer type (:ipc, :cow)
      def consumer_type(type)
        raise Minigun::Error, 'Consumer type must be :ipc or :cow' unless %i[ipc cow].include?(type)

        if type == :cow
          # When setting to :cow, warn about accumulator requirement
          warn 'WARNING: Setting consumer type to :cow. Remember that COW consumers must follow an accumulator stage.'
        end

        @_minigun_config[:consumer_type] = type
      end

      # Set logger for output
      def logger(logger)
        @_minigun_config[:logger] = logger
      end

      # Define the pipeline stages
      def pipeline(&block)
        @_minigun_pipeline_definition = block
      end

      # Process a connection option to determine where to send output
      def process_connection_options(name, options)
        # Extract connection options
        from = options.delete(:from)
        to = options.delete(:to)
        queues = options.delete(:queues) || [:default]

        # Record connections
        @_minigun_connections ||= {}

        # Record "from" connection if specified
        if from
          source_names = from.is_a?(Array) ? from : [from]
          source_names.each do |source_name|
            @_minigun_connections[source_name] ||= []
            @_minigun_connections[source_name] << name unless @_minigun_connections[source_name].include?(name)
          end
        end

        # Record "to" connection if specified
        if to
          target_names = to.is_a?(Array) ? to : [to]
          @_minigun_connections[name] = target_names
        end

        # Record queue subscriptions
        @_minigun_queue_subscriptions ||= {}
        @_minigun_queue_subscriptions[name] = queues.map(&:to_sym)

        # Return the processed options
        options
      end

      # Define the producer block that generates items
      def producer(name = :default, options = {}, &block)
        # Process connection options
        options = process_connection_options(name, options)
        options[:stage_role] = :producer

        # Store the block
        @_minigun_processor_blocks[name] = block if block_given?

        # Record stage in pipeline
        @_minigun_pipeline ||= []
        @_minigun_pipeline << {
          type: :processor, # Use processor type with producer role
          name: name,
          options: options
        }
      end

      # Define a processor block that transforms items
      def processor(name = :default, options = {}, &block)
        # Process connection options
        options = process_connection_options(name, options)
        options[:stage_role] = :processor

        # Store the processor block
        @_minigun_processor_blocks[name] = block if block_given?

        # Record stage in pipeline
        @_minigun_pipeline ||= []
        @_minigun_pipeline << {
          type: :processor,
          name: name,
          options: options
        }
      end

      # Define a specialized accumulator stage
      def accumulator(name = :default, options = {}, &block)
        # Process connection options
        options = process_connection_options(name, options)

        # Extract accumulator-specific options with appropriate defaults
        options[:max_queue] = options.delete(:max_queue) || @_minigun_config[:accumulator_max_queue]
        options[:max_all] = options.delete(:max_all) || @_minigun_config[:accumulator_max_all]
        options[:check_interval] = options.delete(:check_interval) || @_minigun_config[:accumulator_check_interval]

        @_minigun_accumulator_blocks[name] = block if block_given?

        # Record stage in pipeline
        @_minigun_pipeline ||= []
        @_minigun_pipeline << {
          type: :accumulator,
          name: name,
          options: options
        }
      end

      # Define a cow_fork stage (alias for consumer with cow type)
      def cow_fork(name = :default, options = {}, &block)
        # Alias for consumer with cow type
        options = options.merge(fork: :cow)
        consumer(name, options, &block)
      end

      # Define an ipc_fork stage (alias for consumer with ipc type)
      def ipc_fork(name = :default, options = {}, &block)
        # Alias for consumer with ipc type
        options = options.merge(fork: :ipc)
        consumer(name, options, &block)
      end

      # Define a consumer stage
      def consumer(name = :default, options = {}, &block)
        # Process connection options
        options = process_connection_options(name, options)
        options[:stage_role] = :consumer

        # Extract consumer-specific options with appropriate defaults
        # Support fork: as an alternative to type:
        fork_type = options.delete(:fork)
        options[:type] = fork_type || options.delete(:type) || @_minigun_config[:consumer_type]
        options[:max_processes] = options.delete(:max_processes) || @_minigun_config[:max_processes]
        options[:max_threads] = options.delete(:max_threads) || @_minigun_config[:max_threads]
        options[:max_retries] = options.delete(:max_retries) || @_minigun_config[:max_retries]
        options[:batch_size] = options.delete(:batch_size) || @_minigun_config[:batch_size]
        options[:threads] = options.delete(:threads) || options[:max_threads]
        options[:processes] = options.delete(:processes) || options[:max_processes]

        # Store the block
        @_minigun_processor_blocks[name] = block if block_given?

        # Record stage in pipeline
        @_minigun_pipeline ||= []
        @_minigun_pipeline << {
          type: :processor, # Use processor type with consumer role
          name: name,
          options: options
        }

        # If this is a COW consumer type, validate placement
        validate_consumer_placement(:cow, name) if options[:type] == :cow
      end

      # Validate that a consumer stage comes after an accumulator when needed
      def validate_consumer_placement(consumer_type, name)
        # Only validate cow consumers currently
        return unless consumer_type == :cow

        # Find this stage's index
        consumer_index = @_minigun_pipeline.find_index { |s| s[:name] == name && s[:type] == :consumer }
        return unless consumer_index

        # Check if there's an explicit "from" connection to an accumulator
        if @_minigun_connections.any?
          # Look for sources that point to this consumer
          has_accumulator_source = false
          @_minigun_connections.each do |source_name, targets|
            next unless targets.is_a?(Array) ? targets.include?(name) : targets == name

            # Check if source is an accumulator
            source_index = @_minigun_pipeline.find_index { |s| s[:name] == source_name }
            if source_index && @_minigun_pipeline[source_index][:type] == :accumulator
              has_accumulator_source = true
              break
            end
          end

          unless has_accumulator_source
            # For implicit connections, check previous stage
            raise Minigun::Error, "Cow consumer/fork stage '#{name}' must follow an accumulator stage" unless consumer_index > 0

            prev_stage = @_minigun_pipeline[consumer_index - 1]
            raise Minigun::Error, "Cow consumer/fork stage '#{name}' must follow an accumulator stage" unless prev_stage[:type] == :accumulator



          end
        else
          # For sequential pipelines, check previous stage
          raise Minigun::Error, "Cow consumer/fork stage '#{name}' must be preceded by an accumulator stage" unless consumer_index > 0

          prev_stage = @_minigun_pipeline[consumer_index - 1]
          raise Minigun::Error, "Cow consumer/fork stage '#{name}' must follow an accumulator stage" unless prev_stage[:type] == :accumulator



        end
      end

      # Define hooks with options similar to ActionController
      def define_hook(name, options = {}, &block)
        hook_config = { only: [], except: [], if: [], unless: [] }
        hook_config.merge!(options)
        hook_config[:block] = block if block_given?

        @_minigun_hooks[name] ||= []
        @_minigun_hooks[name] << hook_config
      end

      # Define a hook to run before the job starts
      def before_run(options = {}, &block)
        define_hook(:before_run, options, &block)
      end

      # Define a hook to run after the job finishes
      def after_run(options = {}, &block)
        define_hook(:after_run, options, &block)
      end

      # Define a hook to run before forking a consumer process
      def before_fork(options = {}, &block)
        define_hook(:before_fork, options, &block)
      end

      # Define a hook to run after forking a consumer process
      def after_fork(options = {}, &block)
        define_hook(:after_fork, options, &block)
      end

      # Define stage-specific hooks
      def before_stage(name, options = {}, &block)
        stage_name = :"before_stage_#{name.to_s.gsub(/\s+/, '_').downcase}"
        define_hook(stage_name, options, &block)
      end

      def after_stage(name, options = {}, &block)
        stage_name = :"after_stage_#{name.to_s.gsub(/\s+/, '_').downcase}"
        define_hook(stage_name, options, &block)
      end

      def on_stage_error(name, options = {}, &block)
        stage_name = :"on_stage_error_#{name.to_s.gsub(/\s+/, '_').downcase}"
        define_hook(stage_name, options, &block)
      end
    end

    # Start the Minigun job
    def run
      validate_configuration!

      # If a custom pipeline is defined, use it
      if self.class._minigun_pipeline_definition || self.class._minigun_pipeline.any?
        run_custom_pipeline
      else
        # Otherwise, use the simple producer-consumer pattern
        run_simple_pipeline
      end
    end
    alias_method :go_brrr!, :run

    # Add an item to be processed
    def produce(item)
      job_queue = Thread.current[:minigun_queue] || []
      job_queue << item
      Thread.current[:minigun_queue] = job_queue
    end

    # Emit an item to the next stage (used in processor stages)
    def emit(item)
      # This is implemented by the Pipeline class when running
      # Here we just provide it for the DSL
    end

    # Emit an item to a specific queue
    def emit_to_queue(queue, item)
      # Queue routing is handled by the Pipeline class at runtime
      # Here we just provide the method for the DSL
    end

    # Alias for emit_to_queue
    alias_method :enqueue, :emit_to_queue

    # Accumulate an item in the current accumulator
    def accumulate(item, options = {})
      # This is implemented by the Accumulator stage class
      # Here we just provide it for the DSL
    end

    # Run all hooks of a specific type
    def run_hooks(type, *args)
      return unless self.class._minigun_hooks[type]

      self.class._minigun_hooks[type].each do |hook|
        # Check conditions for running the hook
        next if hook[:only].is_a?(Array) && hook[:only].any? && !hook[:only].include?(self.class.name)
        next if hook[:except].is_a?(Array) && hook[:except].any? && hook[:except].include?(self.class.name)

        # No conditions means always run
        if_conditions = hook[:if]
        unless_conditions = hook[:unless]

        # If conditions must all pass
        if if_conditions
          if_conditions = [if_conditions].flatten
          next unless if_conditions.all? do |condition|
            if condition.is_a?(Proc)
              instance_exec(*args, &condition)
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
              instance_exec(*args, &condition)
            else
              condition
            end
          end
        end

        # Execute the hook block
        instance_exec(*args, &hook[:block]) if hook[:block]
      end
    end

    private

    def validate_configuration!
      # Basic validation logic
      # For COW consumer, ensure there's an accumulator before it
      if self.class._minigun_config[:consumer_type] == :cow &&
         self.class._minigun_pipeline.any? { |s| s[:type] == :consumer } &&
         self.class._minigun_pipeline.none? { |s| s[:type] == :accumulator }

        raise Minigun::Error, 'COW consumer requires an accumulator stage before it'
      end
    end

    def run_simple_pipeline
      # Let the Runner handle this simple case
      runner = Minigun::Runner.new(self)
      runner.run
    end

    def run_custom_pipeline
      # Create and run a custom pipeline
      pipeline = Minigun::Pipeline.new(self, custom: true)
      pipeline.run
    end
  end
end
