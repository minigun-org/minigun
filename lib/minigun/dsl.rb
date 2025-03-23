# frozen_string_literal: true

module Minigun
  # The DSL module provides a Domain Specific Language for defining Minigun tasks
  module DSL
    def self.included(base)
      base.extend(ClassMethods)
      base.class_eval do
        # Initialize the task object to be referenced by all DSL methods
        class_variable_set(:@@_minigun_task, Minigun::Task.new) unless class_variable_defined?(:@@_minigun_task)

        # Define class accessor method for minigun task
        class << self
          def _minigun_task
            class_variable_get(:@@_minigun_task)
          end

          def _minigun_config
            _minigun_task.config
          end

          def _minigun_stage_blocks
            _minigun_task.stage_blocks
          end

          def _minigun_hooks
            _minigun_task.hooks
          end

          def _minigun_pipeline
            _minigun_task.pipeline
          end

          def _minigun_pipeline_definition
            _minigun_task.pipeline_definition
          end

          def _minigun_connections
            _minigun_task.connections
          end

          def _minigun_queue_subscriptions
            _minigun_task.queue_subscriptions
          end

          # Class method to start the job
          def run(context = nil)
            _minigun_task.run(context || self)
          end
        end
      end
    end

    # ClassMethods module provides the DSL methods available at the class level
    # for configuring pipelines, stages, hooks, and processing options
    module ClassMethods
      # Set maximum number of threads per consumer process
      def max_threads(value)
        _minigun_task.config[:max_threads] = value
      end

      # Set maximum number of consumer processes to fork
      def max_processes(value)
        _minigun_task.config[:max_processes] = value
      end

      # Alias for max_processes for more intuitive API
      def max_consumer_forks(value)
        max_processes(value)
      end

      # Set maximum retry attempts for failed item processing
      def max_retries(value)
        _minigun_task.config[:max_retries] = value
      end

      # Set batch size for consumer threads
      def batch_size(value)
        _minigun_task.config[:batch_size] = value
      end

      # Set maximum items in a single queue before forking
      def accumulator_max_queue(value)
        _minigun_task.config[:accumulator_max_queue] = value
      end

      # Set maximum items across all queues before forking
      def accumulator_max_all(value)
        _minigun_task.config[:accumulator_max_all] = value
      end

      # Set interval for checking accumulator queues
      def accumulator_check_interval(value)
        _minigun_task.config[:accumulator_check_interval] = value
      end

      # Set forking mode (:auto, :always, :never)
      def fork_mode(mode)
        raise Minigun::Error, 'Fork mode must be :auto, :always, or :never' unless %i[auto always never].include?(mode)

        _minigun_task.config[:fork_mode] = mode
      end

      # Set consumer type (:ipc, :cow)
      def consumer_type(type)
        raise Minigun::Error, 'Consumer type must be :ipc or :cow' unless %i[ipc cow].include?(type)

        if type == :cow
          # When setting to :cow, warn about accumulator requirement
          warn 'WARNING: Setting consumer type to :cow. Remember that COW consumers must follow an accumulator stage.'
        end

        _minigun_task.config[:consumer_type] = type
      end

      # Set logger for output
      def logger(logger)
        _minigun_task.config[:logger] = logger
      end

      # Define the pipeline stages
      def pipeline(&block)
        _minigun_task.pipeline_definition = block
      end

      # Define the producer block that generates items
      def producer(name = :default, options = {}, &block)
        _minigun_task.add_producer(name, options, &block)
      end

      # Define a processor block that transforms items
      def processor(name = :default, options = {}, &block)
        _minigun_task.add_processor(name, options, &block)
      end

      # Define a specialized accumulator stage
      def accumulator(name = :default, options = {}, &block)
        _minigun_task.add_accumulator(name, options, &block)
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
        _minigun_task.add_consumer(name, options, &block)
      end

      # Define a hook to run before the job starts
      def before_run(options = {}, &block)
        _minigun_task.add_hook(:before_run, options, &block)
      end

      # Define a hook to run after the job finishes
      def after_run(options = {}, &block)
        _minigun_task.add_hook(:after_run, options, &block)
      end

      # Define a hook to run before forking a consumer process
      def before_fork(options = {}, &block)
        _minigun_task.add_hook(:before_fork, options, &block)
      end

      # Define a hook to run after forking a consumer process
      def after_fork(options = {}, &block)
        _minigun_task.add_hook(:after_fork, options, &block)
      end

      # Define stage-specific hooks
      def before_stage(name, options = {}, &block)
        stage_name = :"before_stage_#{name.to_s.gsub(/\s+/, '_').downcase}"
        _minigun_task.add_hook(stage_name, options, &block)
      end

      def after_stage(name, options = {}, &block)
        stage_name = :"after_stage_#{name.to_s.gsub(/\s+/, '_').downcase}"
        _minigun_task.add_hook(stage_name, options, &block)
      end

      def on_stage_error(name, options = {}, &block)
        stage_name = :"on_stage_error_#{name.to_s.gsub(/\s+/, '_').downcase}"
        _minigun_task.add_hook(stage_name, options, &block)
      end
    end

    # Instance method to start the job with the current context
    def run
      self.class._minigun_task.run(self)
    end
    alias_method :go_brrr!, :run

    # Add an item to be processed (now just calls emit)
    def produce(item)
      emit(item)
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

    # Run all hooks of a specific type (delegates to task)
    def run_hooks(type, *args)
      self.class.class_variable_get(:@@_minigun_task).run_hooks(type, self, *args)
    end
  end
end
