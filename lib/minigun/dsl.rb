# frozen_string_literal: true

module Minigun
  # DSL for defining Minigun pipelines
  module DSL
    def self.included(base)
      base.extend(ClassMethods)
      base.class_eval do
        # Create a single task instance for the class
        @_minigun_task = Minigun::Task.new
      end
    end

    module ClassMethods
      def _minigun_task
        @_minigun_task
      end

      # Configuration methods
      def max_threads(value)
        _minigun_task.set_config(:max_threads, value)
      end

      def max_processes(value)
        _minigun_task.set_config(:max_processes, value)
      end

      def max_retries(value)
        _minigun_task.set_config(:max_retries, value)
      end

      # Stage definition methods
      def producer(name = :producer, options = {}, &block)
        _minigun_task.add_stage(:producer, name, options, &block)
      end

      def processor(name, options = {}, &block)
        _minigun_task.add_stage(:processor, name, options, &block)
      end

      def accumulator(name = :accumulator, options = {}, &block)
        _minigun_task.add_stage(:accumulator, name, options, &block)
      end

      def consumer(name = :consumer, options = {}, &block)
        _minigun_task.add_stage(:consumer, name, options, &block)
      end

      # Fork aliases
      def cow_fork(name = :consumer, options = {}, &block)
        _minigun_task.add_stage(:consumer, name, options, &block)
      end

      def ipc_fork(name = :consumer, options = {}, &block)
        _minigun_task.add_stage(:consumer, name, options, &block)
      end

      # Hook methods
      def before_run(&block)
        _minigun_task.add_hook(:before_run, &block)
      end

      def after_run(&block)
        _minigun_task.add_hook(:after_run, &block)
      end

      def before_fork(&block)
        _minigun_task.add_hook(:before_fork, &block)
      end

      def after_fork(&block)
        _minigun_task.add_hook(:after_fork, &block)
      end

      # Pipeline block (optional - just for grouping stages)
      def pipeline(&block)
        class_eval(&block)
      end
    end

    # Instance method to run the task
    def run
      self.class._minigun_task.run(self)
    end

    # Convenience aliases
    alias perform run
    alias go_brr! run
    alias go_brrr! run
    alias go_brrrr! run
    alias go_brrrrr! run
  end
end
