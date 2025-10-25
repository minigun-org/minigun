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

      # When a subclass is created, duplicate the parent's task
      def base.inherited(subclass)
        super if defined?(super)
        parent_task = self._minigun_task
        # Create a new task and copy the parent's configuration and pipelines
        new_task = Minigun::Task.new
        new_task.instance_variable_set(:@config, parent_task.config.dup)
        new_task.instance_variable_set(:@implicit_pipeline, parent_task.implicit_pipeline.dup) # Duplicate the pipeline
        subclass.instance_variable_set(:@_minigun_task, new_task)
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

      # Pipeline block - supports three modes:
      # 1. pipeline do...end - Grouping (backward compatible)
      # 2. pipeline :name do...end - Nested pipeline (stage within implicit pipeline)
      # 3. pipeline :name, to: :other - Multi-pipeline (top-level pipeline routing)
      def pipeline(name = nil, options = {}, &block)
        if name.nil?
          # Mode 1: No name, just eval block in class context (backward compatible)
          class_eval(&block)
        elsif options[:to] || _minigun_task.pipelines.any?
          # Mode 3: Has routing or other pipelines exist → Multi-pipeline mode
          _minigun_task.define_pipeline(name, options) do |pipeline|
            # Create a DSL context for this specific pipeline
            pipeline_dsl = PipelineDSL.new(pipeline)
            pipeline_dsl.instance_eval(&block) if block_given?
          end
        else
          # Mode 2: Named but no routing → Nested pipeline stage in implicit pipeline
          # Create a PipelineStage and add it to implicit pipeline
          _minigun_task.add_nested_pipeline(name, options, &block)
        end
      end
    end

    # DSL context for defining stages within a named pipeline
    class PipelineDSL
      def initialize(pipeline)
        @pipeline = pipeline
      end

      # Main unified stage method
      # Stage determines its own type based on block arity
      def stage(name, options = {}, &block)
        # Just pass generic :stage type - Pipeline will create AtomicStage which knows its own type
        @pipeline.add_stage(:stage, name, options, &block)
      end

      # Accumulator is special - kept explicit
      def accumulator(name = :accumulator, options = {}, &block)
        @pipeline.add_stage(:accumulator, name, options, &block)
      end

      # Aliases for backward compatibility (all use inference)
      alias producer stage
      alias processor stage
      alias consumer stage

      # Convenience methods for spawn strategies
      def spawn_thread(name = :consumer, options = {}, &block)
        stage(name, options.merge(strategy: :spawn_thread), &block)
      end

      def spawn_fork(name = :consumer, options = {}, &block)
        stage(name, options.merge(strategy: :spawn_fork), &block)
      end

      def spawn_ractor(name = :consumer, options = {}, &block)
        stage(name, options.merge(strategy: :spawn_ractor), &block)
      end

      def before_run(&block)
        @pipeline.add_hook(:before_run, &block)
      end

      def after_run(&block)
        @pipeline.add_hook(:after_run, &block)
      end

      def after_producer(&block)
        @pipeline.add_hook(:after_producer, &block)
      end

      def before_fork(stage_name = nil, &block)
        if stage_name
          @pipeline.add_stage_hook(:before_fork, stage_name, &block)
        else
          @pipeline.add_hook(:before_fork, &block)
        end
      end

      def after_fork(stage_name = nil, &block)
        if stage_name
          @pipeline.add_stage_hook(:after_fork, stage_name, &block)
        else
          @pipeline.add_hook(:after_fork, &block)
        end
      end

      # Stage-specific hooks (Option 2)
      def before(stage_name, &block)
        @pipeline.add_stage_hook(:before, stage_name, &block)
      end

      def after(stage_name, &block)
        @pipeline.add_stage_hook(:after, stage_name, &block)
      end

      # Routing
      def reroute_stage(from_stage, to:)
        @pipeline.reroute_stage(from_stage, to: to)
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

      # Main unified stage method (for single-pipeline mode)
      # Stage determines its own type based on block arity
      def stage(name, options = {}, &block)
        # Just pass generic :stage type - Pipeline will create AtomicStage which knows its own type
        _minigun_task.add_stage(:stage, name, options, &block)
      end

      # Accumulator is special - kept explicit
      def accumulator(name = :accumulator, options = {}, &block)
        _minigun_task.add_stage(:accumulator, name, options, &block)
      end

      # Aliases for backward compatibility (all use inference)
      alias producer stage
      alias processor stage
      alias consumer stage

      # Convenience methods for spawn strategies
      def spawn_thread(name = :consumer, options = {}, &block)
        stage(name, options.merge(strategy: :spawn_thread), &block)
      end

      def spawn_fork(name = :consumer, options = {}, &block)
        stage(name, options.merge(strategy: :spawn_fork), &block)
      end

      def spawn_ractor(name = :consumer, options = {}, &block)
        stage(name, options.merge(strategy: :spawn_ractor), &block)
      end

      # Hook methods
      def before_run(&block)
        _minigun_task.add_hook(:before_run, &block)
      end

      def after_run(&block)
        _minigun_task.add_hook(:after_run, &block)
      end

      def before_fork(stage_name = nil, &block)
        if stage_name
          _minigun_task.implicit_pipeline.add_stage_hook(:before_fork, stage_name, &block)
        else
          _minigun_task.add_hook(:before_fork, &block)
        end
      end

      def after_fork(stage_name = nil, &block)
        if stage_name
          _minigun_task.implicit_pipeline.add_stage_hook(:after_fork, stage_name, &block)
        else
          _minigun_task.add_hook(:after_fork, &block)
        end
      end

      # Stage-specific hooks (Option 2)
      def before(stage_name, &block)
        _minigun_task.implicit_pipeline.add_stage_hook(:before, stage_name, &block)
      end

      def after(stage_name, &block)
        _minigun_task.implicit_pipeline.add_stage_hook(:after, stage_name, &block)
      end

      # Routing
      def reroute_stage(from_stage, to:)
        _minigun_task.implicit_pipeline.reroute_stage(from_stage, to: to)
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
