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

      # Set maximum number of retries for failed items
      def max_retries(value)
        _minigun_task.config[:max_retries] = value
      end

      # Set batch size for accumulator stages
      def batch_size(value)
        _minigun_task.config[:batch_size] = value
      end

      # Set fork mode for the task
      def fork_mode(value)
        unless [:auto, :never, :always].include?(value.to_sym)
          raise ArgumentError, "Invalid fork mode: #{value}. Must be :auto, :never, or :always"
        end
        _minigun_task.config[:fork_mode] = value.to_sym
      end

      # Set fork type for the task
      def fork_type(value)
        unless [:ipc, :cow].include?(value.to_sym)
          raise ArgumentError, "Invalid fork type: #{value}. Must be :ipc or :cow"
        end
        if value.to_sym == :cow
          warn "Setting fork type to :cow. Remember that COW consumers must follow an accumulator stage."
        end
        _minigun_task.config[:fork_type] = value.to_sym
      end

      # Define a pipeline block
      def pipeline(&block)
        _minigun_task.pipeline_definition = block
      end

      # Define a processor block that transforms items
      def processor(name = :default, options = {}, &block)
        _minigun_task.add_processor(name, options, &block)
      end
      alias_method :consumer, :processor
      alias_method :producer, :processor

      # Define a specialized accumulator stage
      def accumulator(name = :default, options = {}, &block)
        _minigun_task.add_accumulator(name, options, &block)
      end

      # Define a cow_fork stage (alias for consumer with cow type)
      def cow_fork(name = :default, options = {}, &block)
        # Alias for consumer with cow type
        options = options.merge(fork: :cow)
        processor(name, options, &block)
      end

      # Define an ipc_fork stage (alias for consumer with ipc type)
      def ipc_fork(name = :default, options = {}, &block)
        # Alias for consumer with ipc type
        options = options.merge(fork: :ipc)
        processor(name, options, &block)
      end

      # Define a hook to run before the job starts
      def before_run(options = {}, &block)
        _minigun_task.class.before(:run, &block)
      end

      # Define a hook to run after the job finishes
      def after_run(options = {}, &block)
        _minigun_task.class.after(:run, &block)
      end

      # Define a hook to run around the job execution
      def around_run(options = {}, &block)
        _minigun_task.class.around(:run, &block)
      end

      # Define a hook to run before forking a consumer process
      def before_fork(options = {}, &block)
        _minigun_task.class.before(:fork, &block)
      end

      # Define a hook to run after forking a consumer process
      def after_fork(options = {}, &block)
        _minigun_task.class.after(:fork, &block)
      end

      # Define a hook to run around forking
      def around_fork(options = {}, &block)
        _minigun_task.class.around(:fork, &block)
      end

      # Define stage-specific hooks
      def before_stage(name, options = {}, &block)
        _minigun_task.class.before(:stage, &block)
      end

      def after_stage(name, options = {}, &block)
        _minigun_task.class.after(:stage, &block)
      end

      def around_stage(name, options = {}, &block)
        _minigun_task.class.around(:stage, &block)
      end

      # Define processor-specific hooks
      def before_processor_finished(options = {}, &block)
        _minigun_task.class.before(:processor_finished, &block)
      end

      def after_processor_finished(options = {}, &block)
        _minigun_task.class.after(:processor_finished, &block)
      end

      def around_processor_finished(options = {}, &block)
        _minigun_task.class.around(:processor_finished, &block)
      end

      # Define accumulator-specific hooks
      def before_accumulator_finished(options = {}, &block)
        _minigun_task.class.before(:accumulator_finished, &block)
      end

      def after_accumulator_finished(options = {}, &block)
        _minigun_task.class.after(:accumulator_finished, &block)
      end

      def around_accumulator_finished(options = {}, &block)
        _minigun_task.class.around(:accumulator_finished, &block)
      end
    end

    # Instance method to start the job with the current context
    def run
      self.class._minigun_task.run(self)
    end
    alias_method :go_brrr!, :run

    # Emit an item to the next stage (used in processor stages)
    def emit(item)
      Thread.current[:minigun_queue] ||= []
      Thread.current[:minigun_queue] << item
    end

    # Emit an item to a specific queue
    def emit_to_queue(queue, item)
      emit(item)
    end

    # Alias for emit_to_queue
    alias_method :enqueue, :emit_to_queue

    # Run all hooks of a specific type (delegates to task)
    def run_hook(name, *args, &block)
      self.class._minigun_task.run_hook(name, *args, &block)
    end
  end
end
