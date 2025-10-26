# frozen_string_literal: true

module Minigun
  # DSL for defining Minigun pipelines
  module DSL

    module ClassMethods
      def _minigun_task
        @_minigun_task
      end

      # Configuration methods (class-level for defaults)
      def max_threads(value)
        _minigun_task.set_config(:max_threads, value)
      end

      def max_processes(value)
        _minigun_task.set_config(:max_processes, value)
      end

      def max_retries(value)
        _minigun_task.set_config(:max_retries, value)
      end

      # Pipeline block - stores block for later instance-level evaluation
      def pipeline(name = nil, options = {}, &block)
        if name.nil?
          # Store block for evaluation in initialize
          @_pipeline_definition_blocks ||= []
          @_pipeline_definition_blocks << block
        elsif options[:to] || options[:from] || _minigun_task.pipelines.any?
          # Multi-pipeline mode - evaluate at class level for now
          _minigun_task.define_pipeline(name, options) do |pipeline|
            pipeline_dsl = PipelineDSL.new(pipeline, nil)
            pipeline_dsl.instance_eval(&block) if block_given?
          end
        else
          # Nested pipeline - store for instance eval
          @_pipeline_definition_blocks ||= []
          @_pipeline_definition_blocks << lambda { pipeline(name, options, &block) }
        end
      end

      def _pipeline_definition_blocks
        @_pipeline_definition_blocks || []
      end

      # Error messages for stage definitions without pipeline do
      def producer(*)
        raise NoMethodError, stage_definition_error_message(:producer)
      end

      def processor(*)
        raise NoMethodError, stage_definition_error_message(:processor)
      end

      def consumer(*)
        raise NoMethodError, stage_definition_error_message(:consumer)
      end

      def accumulator(*)
        raise NoMethodError, stage_definition_error_message(:accumulator)
      end

      def stage(*)
        raise NoMethodError, stage_definition_error_message(:stage)
      end

      private

      def stage_definition_error_message(method_name)
        <<~ERROR
          Stage definitions must be inside 'pipeline do' block.

          Example:
            class MyPipeline
              include Minigun::DSL

              pipeline do
                #{method_name} :my_stage do
                  # ...
                end
              end
            end

          This allows access to instance variables and runtime configuration.
        ERROR
      end
    end

    # Hook when DSL is included in a class
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
        new_task.instance_variable_set(:@root_pipeline, parent_task.root_pipeline.dup) # Duplicate the pipeline
        subclass.instance_variable_set(:@_minigun_task, new_task)

        # Inherit pipeline definition blocks
        subclass.instance_variable_set(:@_pipeline_definition_blocks, (@_pipeline_definition_blocks || []).dup)
      end
    end

    # Evaluate pipeline blocks in instance context (called before run)
    def _evaluate_pipeline_blocks!
      return if @_pipeline_blocks_evaluated
      @_pipeline_blocks_evaluated = true

      self.class._pipeline_definition_blocks.each do |blk|
        instance_eval(&blk)
      end
    end

    # INSTANCE-LEVEL DSL METHODS

    # Pipeline block wrapper - REQUIRED for stage definitions
    # Supports two modes:
    # 1. pipeline do...end - Main pipeline definition
    # 2. pipeline :name do...end - Named pipeline (multi-pipeline mode)
    def pipeline(name = nil, options = {}, &block)
      if name.nil?
        # Mode 1: Main pipeline - evaluate in instance context
        instance_eval(&block)
      elsif options[:to] || options[:from] || self.class._minigun_task.pipelines.any?
        # Mode 2: Multi-pipeline mode
        self.class._minigun_task.define_pipeline(name, options) do |pipeline|
          # Create a DSL context for this specific pipeline
          pipeline_dsl = PipelineDSL.new(pipeline, self)
          pipeline_dsl.instance_eval(&block) if block_given?
        end
      else
        # Mode 3: Nested pipeline stage
        self.class._minigun_task.add_nested_pipeline(name, options, &block)
      end
    end

    # Stage definition methods (instance-level)
    def producer(name = :producer, options = {}, &block)
      self.class._minigun_task.add_stage(:producer, name, options, &block)
    end

    def processor(name, options = {}, &block)
      self.class._minigun_task.add_stage(:processor, name, options, &block)
    end

    def consumer(name = :consumer, options = {}, &block)
      self.class._minigun_task.add_stage(:consumer, name, options, &block)
    end

    def accumulator(name = :accumulator, options = {}, &block)
      self.class._minigun_task.add_stage(:accumulator, name, options, &block)
    end

    def stage(name, options = {}, &block)
      self.class._minigun_task.add_stage(:stage, name, options, &block)
    end

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

    # Hook methods (instance-level)
    def before_run(&block)
      self.class._minigun_task.add_hook(:before_run, &block)
    end

    def after_run(&block)
      self.class._minigun_task.add_hook(:after_run, &block)
    end

    def before_fork(stage_name = nil, &block)
      if stage_name
        self.class._minigun_task.root_pipeline.add_stage_hook(:before_fork, stage_name, &block)
      else
        self.class._minigun_task.add_hook(:before_fork, &block)
      end
    end

    def after_fork(stage_name = nil, &block)
      if stage_name
        self.class._minigun_task.root_pipeline.add_stage_hook(:after_fork, stage_name, &block)
      else
        self.class._minigun_task.add_hook(:after_fork, &block)
      end
    end

    # Stage-specific hooks
    def before(stage_name, &block)
      self.class._minigun_task.root_pipeline.add_stage_hook(:before, stage_name, &block)
    end

    def after(stage_name, &block)
      self.class._minigun_task.root_pipeline.add_stage_hook(:after, stage_name, &block)
    end

    def after_producer(&block)
      self.class._minigun_task.root_pipeline.add_hook(:after_producer, &block)
    end

    # Routing
    def reroute_stage(from_stage, to:)
      self.class._minigun_task.root_pipeline.reroute_stage(from_stage, to: to)
    end

    # DSL context for defining stages within a named pipeline
    class PipelineDSL
      def initialize(pipeline, context = nil)
        @pipeline = pipeline
        @context = context
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

    # Full production execution with Runner (signal handling, job ID, stats)
    def run
      _evaluate_pipeline_blocks!
      self.class._minigun_task.run(self)
    end

    # Direct pipeline execution (lightweight, no Runner overhead)
    def perform
      _evaluate_pipeline_blocks!
      self.class._minigun_task.perform(self)
    end

    # Convenience aliases
    alias go_brr! run        # Fun production alias
    alias go_brrr! run
    alias go_brrrr! run
    alias go_brrrrr! run
    alias execute perform    # Formal direct execution alias
  end
end
