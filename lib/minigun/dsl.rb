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
        else
          # Named pipeline - always define at class level (multi-pipeline mode)
          # This ensures proper ordering and avoids closure issues
          _minigun_task.define_pipeline(name, options) do |pipeline|
            pipeline_dsl = PipelineDSL.new(pipeline, nil)
            pipeline_dsl.instance_eval(&block) if block_given?
          end
        end
      end

      def _pipeline_definition_blocks
        @_pipeline_definition_blocks || []
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

    # Evaluate pipeline blocks using PipelineDSL (called before run)
    def _evaluate_pipeline_blocks!
      return if @_pipeline_blocks_evaluated
      @_pipeline_blocks_evaluated = true

      self.class._pipeline_definition_blocks.each do |blk|
        # Use PipelineDSL for consistent behavior between named and unnamed pipelines
        pipeline_dsl = PipelineDSL.new(self.class._minigun_task.root_pipeline, self)
        pipeline_dsl.instance_eval(&blk)
      end
    end

    # Pipeline block wrapper - REQUIRED for stage definitions
    # Supports two modes:
    # 1. pipeline do...end - Main pipeline definition (uses PipelineDSL)
    # 2. pipeline :name do...end - Named pipeline (multi-pipeline mode)
    def pipeline(name = nil, options = {}, &block)
      if name.nil?
        # Mode 1: Main pipeline - use PipelineDSL
        pipeline_dsl = PipelineDSL.new(self.class._minigun_task.root_pipeline, self)
        pipeline_dsl.instance_eval(&block)
      elsif options[:to] || options[:from] || self.class._minigun_task.pipelines.any?
        # Mode 2: Multi-pipeline mode
        self.class._minigun_task.define_pipeline(name, options) do |pipeline|
          pipeline_dsl = PipelineDSL.new(pipeline, self)
          pipeline_dsl.instance_eval(&block) if block_given?
        end
      else
        # Mode 3: Nested pipeline stage
        self.class._minigun_task.add_nested_pipeline(name, options, &block)
      end
    end

    # Context management for PipelineDSL when @context is set
    def _execution_context_stack
      @_execution_context_stack ||= []
    end

    def _named_contexts
      @_named_contexts ||= {}
    end

    # DSL context for defining stages within a named pipeline
    class PipelineDSL
      def initialize(pipeline, context = nil)
        @pipeline = pipeline
        @context = context
        @_execution_context_stack = []
        @_named_contexts = {}
        @_batch_counter = 0
      end

      # Execution context stack management
      def _execution_context_stack
        @_execution_context_stack
      end

      def _named_contexts
        @_named_contexts
      end

      def _current_execution_context
        _execution_context_stack.last
      end

      # Execution block methods
      def threads(pool_size, &block)
        context = { type: :threads, pool_size: pool_size, mode: :pool }
        _with_execution_context(context, &block)
      end

      def processes(pool_size, &block)
        context = { type: :processes, pool_size: pool_size, mode: :pool }
        _with_execution_context(context, &block)
      end

      def ractors(pool_size, &block)
        context = { type: :ractors, pool_size: pool_size, mode: :pool }
        _with_execution_context(context, &block)
      end

      def thread_per_batch(max:, &block)
        context = { type: :threads, max: max, mode: :per_batch }
        _with_execution_context(context, &block)
      end

      def process_per_batch(max:, &block)
        context = { type: :processes, max: max, mode: :per_batch }
        _with_execution_context(context, &block)
      end

      def ractor_per_batch(max:, &block)
        context = { type: :ractors, max: max, mode: :per_batch }
        _with_execution_context(context, &block)
      end

      # Batching shorthand
      def batch(size)
        batch_num = @_batch_counter
        @_batch_counter += 1
        accumulator(:"_batch_#{batch_num}", max_size: size)
      end

      # Named execution context definition
      def execution_context(name, type, size_or_max)
        ctx_def = {
          type: type,
          pool_size: size_or_max,
          mode: :pool
        }

        # Store in instance context if available, otherwise in PipelineDSL
        if @context && @context.respond_to?(:_named_contexts)
          @context._named_contexts[name] = ctx_def
        else
          _named_contexts[name] = ctx_def
        end
      end

      # Nested pipeline support
      def pipeline(name, options = {}, &block)
        # This handles nested pipeline stages within a pipeline block
        if @context
          @context.class._minigun_task.add_nested_pipeline(name, options, &block)
        else
          raise "Nested pipelines require instance context"
        end
      end

      # Main unified stage method
      # Stage determines its own type based on block arity
      def stage(name, options = {}, &block)
        options = _apply_execution_context(options)
        # Just pass generic :stage type - Pipeline will create AtomicStage which knows its own type
        @pipeline.add_stage(:stage, name, options, &block)
      end

      # Accumulator is special - kept explicit
      def accumulator(name = :accumulator, options = {}, &block)
        options = _apply_execution_context(options)
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

      private

      def _with_execution_context(context, &block)
        _execution_context_stack.push(context)
        begin
          instance_eval(&block)
        ensure
          _execution_context_stack.pop
        end
      end

      def _apply_execution_context(options)
        # If @context exists (instance context), check its named contexts first
        if options[:execution_context]
          context_name = options[:execution_context]
          named_ctx = if @context && @context.respond_to?(:_named_contexts)
                       @context._named_contexts[context_name]
                     else
                       _named_contexts[context_name]
                     end

          if named_ctx
            options[:_execution_context] = named_ctx
          else
            raise ArgumentError, "Unknown execution context: #{context_name}"
          end
        elsif _current_execution_context
          # Use current context from stack
          options[:_execution_context] = _current_execution_context
        end
        options
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
