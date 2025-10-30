# frozen_string_literal: true

module Minigun
  # DSL for defining Minigun pipelines
  module DSL
    # Class-level methods for pipeline definition
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

      # Set default execution context for all stages
      def execution(type, max: nil)
        _minigun_task.set_config(:_default_execution_context, { type: type, pool_size: max })
      end

      # Pipeline block - stores block for lazy instance-level evaluation
      # All pipeline definitions (both unnamed and named) are stored and evaluated at instance time
      # This allows blocks to access instance variables correctly
      def pipeline(name = nil, options = {}, &block)
        @_pipeline_definition_blocks ||= []
        @_pipeline_definition_blocks << { name: name, options: options, block: block }
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

      # Add class-level attribute accessors to set when inheriting
      class << base
        attr_accessor :_minigun_task, :_pipeline_definition_blocks
      end

      base.class_eval do
        # Create a single task instance for the class
        @_minigun_task = Minigun::Task.new
        # Reset pipeline blocks to prevent accumulation across load calls
        @_pipeline_definition_blocks = []
      end

      # When a subclass is created, duplicate the parent's task
      def base.inherited(subclass)
        super if defined?(super)
        parent_task = _minigun_task
        # Create a new task and copy the parent's configuration and pipelines
        new_task = Minigun::Task.new(
          config: parent_task.config.dup,
          root_pipeline: parent_task.root_pipeline.dup
        )
        subclass._minigun_task = new_task

        # Inherit pipeline definition blocks (deep dup to avoid shared hashes)
        subclass.instance_variable_set(
          :@_pipeline_definition_blocks,
          (@_pipeline_definition_blocks || []).map(&:dup)
        )
      end
    end

    # Instance-level task (deep copy of class blueprint, created at execution time)
    attr_reader :_minigun_task

    # Evaluate pipeline blocks using PipelineDSL (called before run)
    # Creates an instance-level deep copy of the class task for execution isolation
    def _evaluate_pipeline_blocks!
      return if @_pipeline_blocks_evaluated

      @_pipeline_blocks_evaluated = true

      # Deep copy class-level task for this instance
      # This prevents shared state across multiple runs/instances
      class_task = self.class._minigun_task
      @_minigun_task = Minigun::Task.new(
        config: class_task.config.dup,
        root_pipeline: class_task.root_pipeline.dup
      )

      # Evaluate stored pipeline blocks on instance task with instance context
      self.class._pipeline_definition_blocks.each do |entry|
        name = entry[:name]
        opts = entry[:options]

        if name
          # Named pipeline - define on instance task, then evaluate block with instance context
          @_minigun_task.define_pipeline(name, opts) do |pipeline|
            pipeline_dsl = PipelineDSL.new(pipeline, self)
            _pipeline_dsl_stack.push(pipeline_dsl)
            begin
              # Evaluate in instance context so @config, @results etc. are accessible
              instance_eval(&entry[:block])
            rescue => e
              raise
            ensure
              _pipeline_dsl_stack.pop
            end
          end
        else
          # Unnamed pipeline - evaluate with instance context on root pipeline
          pipeline_dsl = PipelineDSL.new(@_minigun_task.root_pipeline, self)
          _pipeline_dsl_stack.push(pipeline_dsl)
          begin
            # Evaluate in instance context so @config, @results etc. are accessible
            instance_eval(&entry[:block])
          rescue => e
            raise
          ensure
            _pipeline_dsl_stack.pop
          end
        end
      end
    end

    # Pipeline DSL delegation stack - allows nested pipelines to delegate correctly
    def _pipeline_dsl_stack
      @_pipeline_dsl_stack ||= []
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
      attr_reader :_execution_context_stack

      attr_reader :_named_contexts

      def _current_execution_context
        _execution_context_stack.last
      end

      # Unified pipeline creation - ALL pipelines are the same!
      # Can have executor configuration or be anonymous nested pipelines
      def pipeline(name = nil, options = {}, &block)
        # Generate a unique name if not provided
        name ||= :"_pipeline_#{object_id}_#{@pipeline.stages.size}"

        # Merge executor options if provided
        pipeline_options = options.dup

        # Create the nested pipeline
        _add_nested_pipeline(name, pipeline_options, &block)
      end

      # Execution block methods - these are just shortcuts for pipeline with executor config
      def threads(pool_size, &block)
        pipeline(executor: :threads, pool_size: pool_size, &block)
      end

      def processes(pool_size, &block)
        pipeline(executor: :cow_forks, pool_size: pool_size, &block)
      end

      def ractors(pool_size, &block)
        pipeline(executor: :ractors, pool_size: pool_size, &block)
      end

      def thread_per_batch(max:, &block)
        pipeline(executor: :threads, max: max, mode: :per_batch, &block)
      end

      def process_per_batch(max:, &block)
        pipeline(executor: :cow_forks, max: max, mode: :per_batch, &block)
      end

      def ractor_per_batch(max:, &block)
        pipeline(executor: :ractors, max: max, mode: :per_batch, &block)
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
        if @context.respond_to?(:_named_contexts)
          @context._named_contexts[name] = ctx_def
        else
          _named_contexts[name] = ctx_def
        end
      end

      # Main unified stage method
      # Stage determines its own type based on block arity
      # Producer - generates items, receives output queue
      def producer(name, options = {}, &)
        options = _apply_execution_context(options)
        options[:stage_type] = :producer
        @pipeline.add_stage(:stage, name, options, &)
      end

      # Consumer - processes items, receives item and output queue
      # Whether it uses output or not is up to the stage implementation
      def consumer(name, options = {}, &)
        options = _apply_execution_context(options)
        options[:stage_type] = :consumer
        @pipeline.add_stage(:stage, name, options, &)
      end

      # Processor - alias for consumer (both receive item and output)
      alias_method :processor, :consumer

      # Generic stage - for advanced use (input loop), receives input and output queues
      def stage(name, options = {}, &)
        options = _apply_execution_context(options)
        options[:stage_type] = :stage
        @pipeline.add_stage(:stage, name, options, &)
      end

      # Custom stage - for using custom Stage subclasses
      # Pass a Stage class as the first argument instead of a symbol
      def custom_stage(stage_class, name, options = {})
        options = _apply_execution_context(options)
        @pipeline.add_stage(stage_class, name, options)
      end

      # Accumulator is special - kept explicit
      def accumulator(name = :accumulator, options = {}, &)
        options = _apply_execution_context(options)
        @pipeline.add_stage(:accumulator, name, options, &)
      end

      def before_run(&)
        @pipeline.add_hook(:before_run, &)
      end

      def after_run(&)
        @pipeline.add_hook(:after_run, &)
      end

      def after_producer(&)
        @pipeline.add_hook(:after_producer, &)
      end

      def before_fork(stage_name = nil, &)
        if stage_name
          @pipeline.add_stage_hook(:before_fork, stage_name, &)
        else
          @pipeline.add_hook(:before_fork, &)
        end
      end

      def after_fork(stage_name = nil, &)
        if stage_name
          @pipeline.add_stage_hook(:after_fork, stage_name, &)
        else
          @pipeline.add_hook(:after_fork, &)
        end
      end

      # Stage-specific hooks (Option 2)
      def before(stage_name, &)
        @pipeline.add_stage_hook(:before, stage_name, &)
      end

      def after(stage_name, &)
        @pipeline.add_stage_hook(:after, stage_name, &)
      end

      # Routing
      def reroute_stage(from_stage, to:)
        @pipeline.reroute_stage(from_stage, to: to)
      end

      private

      # Unified method for creating ALL nested pipelines
      # Handles both executor-configured pipelines and regular nested pipelines
      def _add_nested_pipeline(name, options = {}, &block)
        # Convert executor options to _execution_context format if present
        stage_options = options.dup
        has_executor = false
        if options[:executor]
          has_executor = true
          executor_type = options[:executor]
          # Normalize executor type names (threads -> thread, cow_forks -> cow_fork)
          normalized_type = case executor_type
                           when :threads then :thread
                           when :cow_forks then :cow_fork
                           when :ractors then :ractor
                           else executor_type
                           end

          exec_ctx = {
            type: normalized_type,
            pool_size: options[:pool_size] || options[:max],
            mode: options[:mode] || :pool
          }
          stage_options[:_execution_context] = exec_ctx
        end

        # Use ExecutorStage if executor config is present, otherwise use PipelineStage
        stage_class = has_executor ? Minigun::ExecutorStage : Minigun::PipelineStage
        pipeline_stage = stage_class.new(@pipeline, name, nil, stage_options)

        # Create the actual Pipeline instance for this nested pipeline
        nested_pipeline_config = {}
        # If executor options were provided, set as default execution context for nested pipeline
        # This makes all stages within the nested pipeline use this executor by default
        if stage_options[:_execution_context]
          nested_pipeline_config[:_default_execution_context] = stage_options[:_execution_context]
        end

        nested_pipeline = Minigun::Pipeline.new(@pipeline.task, name, nested_pipeline_config)
        pipeline_stage.nested_pipeline = nested_pipeline

        # Add stages to the nested pipeline via block
        if block
          nested_dsl = Minigun::DSL::PipelineDSL.new(nested_pipeline, @context)

          if @context
            # Push nested DSL onto the context's delegation stack
            # This allows the block to be evaluated in the user's instance context
            # while DSL method calls are delegated to the nested_dsl via method_missing stack
            @context._pipeline_dsl_stack.push(nested_dsl)
            begin
              # Evaluate in the user's instance context to allow access to @config, @results, etc.
              @context.instance_eval(&block)
            ensure
              @context._pipeline_dsl_stack.pop
            end
          else
            # No context - evaluate in PipelineDSL context
            nested_dsl.instance_eval(&block)
          end
        end

        # Add the pipeline stage to the current pipeline by ID (stage already registered in Task)
        pipeline_stage_id = pipeline_stage.id
        @pipeline.stages[pipeline_stage_id] = pipeline_stage
        @pipeline.stage_order << pipeline_stage_id
        @pipeline.dag.add_node(pipeline_stage_id)

        pipeline_stage
      end

      def _with_execution_context(context, &)
        _execution_context_stack.push(context)
        begin
          instance_eval(&)
        ensure
          _execution_context_stack.pop
        end
      end

      def _apply_execution_context(options)
        # If @context exists (instance context), check its named contexts first
        if options[:execution_context]
          context_name = options[:execution_context]
          named_ctx = if @context.respond_to?(:_named_contexts)
                        @context._named_contexts[context_name]
                      else
                        _named_contexts[context_name]
                      end

          raise ArgumentError, "Unknown execution context: #{context_name}" unless named_ctx

          options[:_execution_context] = named_ctx
        elsif _current_execution_context
          # Use current context from stack
          options[:_execution_context] = _current_execution_context
        elsif @pipeline && @pipeline.config[:_default_execution_context]
          # Use default execution context from config
          default_ctx = @pipeline.config[:_default_execution_context]
          options[:_execution_context] = {
            type: default_ctx[:type],
            pool_size: default_ctx[:pool_size],
            mode: :pool
          }
        end

        # Normalize the type if an execution context was set
        if options[:_execution_context] && options[:_execution_context][:type]
          options[:_execution_context][:type] = normalize_execution_type(options[:_execution_context][:type])
        end

        options
      end

      def normalize_execution_type(type)
        type.to_s.delete_suffix('s').delete_suffix('_pool').to_sym
      end
    end

    # Delegate DSL method calls through the pipeline_dsl stack recursively
    # Checks each level from top to bottom until method is found
    def method_missing(method_name, *args, **kwargs, &block)
      stack = _pipeline_dsl_stack
      stack.reverse_each do |dsl|
        if dsl.respond_to?(method_name, true)
          return dsl.send(method_name, *args, **kwargs, &block)
        end
      end
      super
    end

    def respond_to_missing?(method_name, include_private = false)
      _pipeline_dsl_stack.reverse_each do |dsl|
        return true if dsl.respond_to?(method_name, include_private)
      end
      super
    end

    # Full production execution with Runner (signal handling, job ID, stats)
    def run
      _evaluate_pipeline_blocks!
      @_minigun_task.run(self)
    end

    # Direct pipeline execution (lightweight, no Runner overhead)
    def perform
      _evaluate_pipeline_blocks!
      @_minigun_task.root_pipeline.run(self)
    end

    # Convenience aliases
    alias_method :go_brr!, :run        # Fun production alias
    alias_method :go_brrr!, :run
    alias_method :go_brrrr!, :run
    alias_method :go_brrrrr!, :run
    alias_method :execute, :perform    # Formal direct execution alias
  end
end
