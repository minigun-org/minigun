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
      # TODO: should this be the default?? or for the current scope
      def execution(type, max)
        _minigun_task.set_config(:_default_execution_context, { type: type, pool_size: max })
      end

      # Pipeline block - stores block for lazy instance-level evaluation
      # All pipeline definitions (both unnamed and named) are stored and evaluated at instance time
      # This allows blocks to access instance variables correctly
      # The :source field tracks whether this block was defined in this class (:self) or inherited (:inherited)
      def pipeline(name = nil, options = {}, &block)
        @_pipeline_definition_blocks ||= []
        @_pipeline_definition_blocks << { name: name, options: options, block: block, source: :self }
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
        # Create a new task with parent's configuration (don't copy pipeline - it's rebuilt from blocks)
        new_task = Minigun::Task.new(
          config: parent_task.config.dup
        )
        subclass._minigun_task = new_task

        # Inherit pipeline definition blocks, marking them as :inherited
        # Deep dup to avoid shared hashes, and update source to :inherited
        parent_blocks = (@_pipeline_definition_blocks || []).map do |entry|
          entry.dup.merge(source: :inherited)
        end
        subclass.instance_variable_set(:@_pipeline_definition_blocks, parent_blocks)
      end
    end

    # Instance-level task (deep copy of class blueprint, created at execution time)
    attr_reader :_minigun_task

    # Evaluate pipeline blocks using PipelineDSL (called before run)
    # Creates an instance-level deep copy of the class task for execution isolation
    #
    # Pipeline Inheritance Rules:
    # 1. Unnamed pipelines: always evaluate on root_pipeline (stages accessible by named pipelines)
    # 2. Named pipelines: always extend when same name is declared again
    # 3. For inheritance: child's blocks extend parent's (all combined appropriately)
    #
    # Key insight: unnamed pipelines provide "shared" stages that named pipelines can route to.
    # Multiple unnamed pipelines from same class all go on root (their stages coexist).
    def _evaluate_pipeline_blocks!
      return if @_pipeline_blocks_evaluated

      @_pipeline_blocks_evaluated = true

      # Create a fresh task for this instance with config from class task
      class_task = self.class._minigun_task
      @_minigun_task = Minigun::Task.new(
        config: class_task.config.dup
      )

      blocks = self.class._pipeline_definition_blocks
      return if blocks.empty?

      # Separate unnamed and named blocks
      unnamed_blocks = blocks.select { |b| b[:name].nil? }
      named_blocks = blocks.reject { |b| b[:name].nil? }

      # Track which named pipelines have been created (for extension)
      created_pipelines = {}

      # Process unnamed pipelines first - they go on root_pipeline
      # This allows named pipelines to route to/from their stages
      unnamed_blocks.each do |entry|
        _evaluate_block_on_root(entry)
      end

      # Process named pipelines (allows extension when same name appears multiple times)
      named_blocks.each do |entry|
        name = entry[:name]
        if created_pipelines[name]
          _extend_named_pipeline(name, entry)
        else
          created_pipelines[name] = _create_named_pipeline(name, entry)
        end
      end
    end

    private

    # Evaluate a pipeline block directly on root_pipeline (for single unnamed pipeline)
    def _evaluate_block_on_root(entry)
      pipeline_dsl = PipelineDSL.new(@_minigun_task.root_pipeline, self)
      _pipeline_dsl_stack.push(pipeline_dsl)
      begin
        instance_eval(&entry[:block])
      ensure
        _pipeline_dsl_stack.pop
      end
    end

    # Create a new named pipeline as a PipelineStage
    def _create_named_pipeline(name, entry)
      @_minigun_task.define_pipeline(name, entry[:options]) do |pipeline|
        pipeline_dsl = PipelineDSL.new(pipeline, self)
        _pipeline_dsl_stack.push(pipeline_dsl)
        begin
          instance_eval(&entry[:block])
        ensure
          _pipeline_dsl_stack.pop
        end
      end
    end

    # Extend an existing named pipeline by adding stages to it
    def _extend_named_pipeline(name, entry)
      pipeline_stage = @_minigun_task.root_pipeline.find_stage(name)
      unless pipeline_stage
        raise Errors::UnresolvedReference.new(
          "Pipeline '#{name}' not found for extension",
          reference: name
        )
      end

      pipeline = pipeline_stage.nested_pipeline
      pipeline_dsl = PipelineDSL.new(pipeline, self)
      _pipeline_dsl_stack.push(pipeline_dsl)
      begin
        instance_eval(&entry[:block])
      ensure
        _pipeline_dsl_stack.pop
      end
    end

    # Create an isolated pipeline for an unnamed block
    def _create_isolated_pipeline(entry)
      # Generate unique name for unnamed pipeline
      isolated_name = :"_pipeline_#{SecureRandom.uuid.tr('-', '')}"

      @_minigun_task.define_pipeline(isolated_name, entry[:options]) do |pipeline|
        pipeline_dsl = PipelineDSL.new(pipeline, self)
        _pipeline_dsl_stack.push(pipeline_dsl)
        begin
          instance_eval(&entry[:block])
        ensure
          _pipeline_dsl_stack.pop
        end
      end
    end

    public

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

    # Delegate DSL method calls through the pipeline_dsl stack
    # Checks each level from top to bottom until method is found
    def method_missing(method_name, ...)
      stack = _pipeline_dsl_stack
      stack.reverse_each do |dsl|
        if dsl.respond_to?(method_name, true)
          return dsl.send(method_name, ...)
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

    # DSL context for defining stages within a named pipeline
    class PipelineDSL
      def initialize(pipeline, context = nil)
        @pipeline = pipeline
        @context = context
        @_execution_context_stack = []
        @_named_contexts = {}
      end

      # Execution context stack management
      attr_reader :_execution_context_stack

      attr_reader :_named_contexts

      def _current_execution_context
        _execution_context_stack.last
      end

      # Execution block methods
      def in_fibers(pool_size, pool_timeout: nil, &)
        context = { type: :fiber_pool, pool_size: pool_size, pool_timeout: pool_timeout }
        _with_execution_context(context, &)
      end

      def in_threads(pool_size, &)
        context = { type: :thread_pool, pool_size: pool_size }
        _with_execution_context(context, &)
      end

      def in_ractors(pool_size, &)
        # Ractor execution requires shareable blocks, so automatically apply shareable_auto: true
        # to all stages defined within this block. This differs from explicit shareable: true
        # in that failures will warn and fall back to threads instead of raising an error.
        context = { type: :ractor_pool, pool_size: pool_size, shareable_auto: true }
        _with_execution_context(context, &)
      end

      def in_cow_forks(pool_size, &)
        context = { type: :cow_fork, pool_size: pool_size }
        _with_execution_context(context, &)
      end

      # IPC Fork execution - persistent worker processes with IPC pipes
      #
      # @param pool_size [Integer] Number of worker processes to spawn
      # @param restart_policy [Symbol] Worker restart policy on failure (default: :never)
      #   - :never: Don't restart failed workers (default)
      #   - :transient: Restart workers that exit abnormally (non-zero exit or signal)
      #   - :permanent: Always restart workers that exit for any reason
      # @param max_restarts [Integer] Maximum restarts per worker before giving up (default: 3)
      # @param restart_window [Integer] Time window in seconds for counting restarts (default: 60)
      #
      # @example Basic usage
      #   in_ipc_forks(4) do
      #     processor :compute do |item, output|
      #       output << expensive_calculation(item)
      #     end
      #   end
      #
      # @example With worker restart on failures
      #   in_ipc_forks(4, restart_policy: :transient) do
      #     processor :compute do |item, output|
      #       output << risky_operation(item)
      #     end
      #   end
      def in_ipc_forks(pool_size, restart_policy: :never, max_restarts: 3, restart_window: 60, &)
        context = {
          type: :ipc_fork,
          pool_size: pool_size,
          restart_policy: restart_policy,
          max_restarts: max_restarts,
          restart_window: restart_window
        }
        _with_execution_context(context, &)
      end

      # Distributed cluster execution - distributes work across remote machines via DRb
      #
      # Two modes available:
      # 1. Coordinator mode: Workers connect to a coordinator which distributes work
      # 2. Direct mode: Connect directly to workers without a coordinator
      #
      # @param coordinator_uri [String] DRb URI of the coordinator (e.g., "druby://10.0.0.1:9000")
      # @param worker_uris [Array<String>] Array of worker URIs for direct mode (no coordinator)
      # @param min_workers [Integer] Minimum workers required before starting (default: 1, coordinator mode only)
      # @param worker_timeout [Integer] Seconds to wait for workers to connect (default: 30)
      # @param shutdown_on_done [Boolean] Shutdown workers when stage completes (default: false, direct mode only)
      #
      # @example Coordinator mode (coordinator auto-starts, workers connect dynamically)
      #   in_cluster(coordinator_uri: 'druby://0.0.0.0:9000') do
      #     processor :compute do |item, output|
      #       output << expensive_computation(item)
      #     end
      #   end
      #
      # @example Coordinator mode with minimum workers requirement
      #   in_cluster(coordinator_uri: 'druby://10.0.0.1:9000', min_workers: 3, worker_timeout: 60) do
      #     processor :distributed_work do |item, output|
      #       output << process(item)
      #     end
      #   end
      #
      # @example Direct mode (connect to workers directly, no coordinator)
      #   in_cluster(worker_uris: ['druby://w1:9001', 'druby://w2:9002']) do
      #     processor :distributed_work do |item, output|
      #       output << process(item)
      #     end
      #   end
      #
      # @example Direct mode with shutdown (for dedicated workers)
      #   in_cluster(worker_uris: ['druby://w1:9001'], shutdown_on_done: true) do
      #     processor :one_time_job do |item, output|
      #       output << process(item)
      #     end
      #   end
      #
      # NOTE: Worker nodes must have the same codebase deployed and must register
      # stage processors locally. The stage block is NOT serialized to workers.
      # Execute stages on remote cluster workers via DRb
      #
      # Delivery modes:
      #   :at_most_once (default) - Items may be lost on worker failure, but never duplicated
      #   :at_least_once - Items are retried on failure; duplicates possible
      #
      # @param coordinator_uri [String] DRb URI for coordinator-based distribution
      # @param worker_uris [Array<String>] Direct worker URIs for round-robin distribution
      # @param min_workers [Integer] Minimum workers required (coordinator mode only)
      # @param worker_timeout [Integer] Seconds to wait for workers
      # @param shutdown_on_done [Boolean] Send shutdown signal to workers when done
      # @param delivery_mode [Symbol] :at_most_once or :at_least_once
      # @param max_retries [Integer] Max retry attempts per item (at_least_once only)
      def in_cluster(coordinator_uri: nil, worker_uris: nil, min_workers: 1, worker_timeout: 30,
                     shutdown_on_done: false, delivery_mode: :at_most_once, max_retries: 3, &)
        unless coordinator_uri || worker_uris
          raise Errors::InvalidOption.new(
            option_name: :in_cluster,
            expected: 'either coordinator_uri: or worker_uris:'
          )
        end
        if coordinator_uri && worker_uris
          raise Errors::InvalidOption.new(
            option_name: :in_cluster,
            expected: 'only one of coordinator_uri: or worker_uris: (not both)'
          )
        end
        unless %i[at_most_once at_least_once].include?(delivery_mode)
          raise Errors::InvalidOption.new(
            option_name: :delivery_mode,
            value: delivery_mode,
            expected: ':at_most_once or :at_least_once'
          )
        end

        context = {
          type: :cluster_pool,
          coordinator_uri: coordinator_uri,
          worker_uris: worker_uris,
          min_workers: min_workers,
          worker_timeout: worker_timeout,
          shutdown_on_done: shutdown_on_done,
          delivery_mode: delivery_mode,
          max_retries: max_retries
        }
        _with_execution_context(context, &)
      end

      # Batch: Collects items into batches before passing downstream
      # @param name_or_size [Symbol, Integer] Stage name or batch size (shorthand)
      # @param options [Hash] Stage options including :max_size, :max_wait
      # @yield [batch, output] Block to process each batch (optional)
      #
      # Examples:
      #   batch(10)                              # Shorthand: batch into groups of 10
      #   batch(:batcher, max_size: 50)          # Named batch stage
      #   batch(:writer, max_size: 100) do |batch, output|
      #     BulkWriter.insert(batch)
      #   end
      def batch(name_or_size = nil, options = {}, &block)
        # Handle shorthand: batch(10) means batch(nil, max_size: 10)
        if name_or_size.is_a?(Integer)
          options = { max_size: name_or_size }.merge(options)
          name = nil
        else
          name = name_or_size
        end

        options = _apply_execution_context(options)
        @pipeline.add_stage(:batch, name, options, &block)
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

      # Nested pipeline support
      def pipeline(name, options = {}, &)
        # This handles nested pipeline stages within a pipeline block
        raise 'Nested pipelines require instance context' unless @context

        # Get the task from context (instance or class)
        task = @context._minigun_task
        task.add_nested_pipeline(name, options, &)
      end

      # Producer - block-based, you write the loop
      # producer(:name) { |out| items.each { |i| out << i } }
      def producer(name = nil, options = {}, &)
        options = _apply_execution_context(options)
        options[:stage_type] = :producer
        @pipeline.add_stage(:stage, name, options, &)
      end

      # Producer from enumerable - we iterate for you
      # - produce_each :name, [1,2,3]         # enumerable
      # - produce_each :name, -> { User.all } # proc/lambda
      # - produce_each :name, :fetch_users    # method symbol (called on context)
      # - produce_each(:name) { User.all }    # block returning enumerable
      # - produce_each [1,2,3]                # unnamed
      def produce_each(name_or_source = nil, source_or_opts = nil, opts = {}, &block)
        if name_or_source.is_a?(Symbol) && (source_or_opts || block)
          # produce_each :name, source  OR  produce_each(:name) { }
          name = name_or_source
          source = block || source_or_opts
          opts = {} unless opts.is_a?(Hash)
        else
          # produce_each source  (unnamed)
          name = nil
          source = block || name_or_source
          opts = source_or_opts.is_a?(Hash) ? source_or_opts : {}
        end

        unless source && (source.respond_to?(:each) || source.respond_to?(:call) || source.is_a?(Symbol))
          raise Errors::InvalidOption.new(
            option_name: :source,
            value: source,
            expected: 'enumerable, proc, method name, or block for produce_each'
          )
        end

        opts = _apply_execution_context(opts)
        opts[:stage_type] = :enumerator_producer
        opts[:_enumerator_source] = source

        @pipeline.add_stage(:stage, name, opts)
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

      # Aliases for simplified DSL
      alias_method :produce, :producer
      alias_method :consume, :consumer

      # Debatch: Unpacks Array items into individual items
      # Receives Array<T> and emits T for each element
      # @param name [Symbol] Optional stage name (auto-generated if nil)
      # @param options [Hash] Stage options
      def debatch(name = nil, options = {})
        options = _apply_execution_context(options)
        options[:stage_type] = :consumer
        @pipeline.add_stage(DebatchStage, name, options)
      end

      # Rebatch: Re-batches incoming batches into new batch sizes
      # Receives batches (items responding to #each) and emits new batches of specified size
      # @param size [Integer] New batch size
      # @param name [Symbol] Optional stage name (auto-generated if nil)
      # @param options [Hash] Stage options
      def rebatch(size, name = nil, options = {})
        options = _apply_execution_context(options)
        options[:stage_type] = :consumer
        options[:_rebatch_size] = size

        @pipeline.add_stage(RebatchStage, name, options)
      end

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

      def _with_execution_context(context, &)
        _execution_context_stack.push(context)
        begin
          if @context
            # Evaluate in user's instance context to allow access to @config, @results, etc.
            @context.instance_eval(&)
          else
            # No context - evaluate in PipelineDSL context
            instance_eval(&)
          end
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

          unless named_ctx
            raise Errors::InvalidOption.new(
              option_name: :execution_context,
              value: context_name,
              expected: 'a defined named context'
            )
          end

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

        # Propagate shareable options from execution context to main options
        # shareable_auto: from in_ractors - warns on failure and falls back to threads
        # shareable: explicit user request - raises error on failure
        if options[:_execution_context]&.[](:shareable_auto) && !options.key?(:shareable) && !options.key?(:shareable_auto)
          options[:shareable_auto] = true
        elsif options[:_execution_context]&.[](:shareable) && !options.key?(:shareable)
          options[:shareable] = true
        end

        options
      end

      def normalize_execution_type(type)
        type.to_s.delete_suffix('s').delete_suffix('_pool').to_sym
      end
    end

    # Full production execution with Runner (signal handling, job ID, stats)
    # Options:
    #   background: true - Run in background thread (returns immediately)
    def run(background: false)
      _evaluate_pipeline_blocks!

      if background
        # Run in background thread for IRB/console usage
        @_background_thread = Thread.new do
          @_minigun_task.run(self)
        rescue StandardError => e
          warn "Background task error: #{e.message}"
          warn e.backtrace.join("\n")
        end

        # Give it a moment to start
        sleep 0.1

        puts "Task running in background (Thread ##{@_background_thread.object_id})"
        puts 'Use task.hud to open the HUD monitor'
        puts 'Use task.stop to stop execution'
        self
      else
        @_minigun_task.run(self)
      end
    end

    # Direct pipeline execution (lightweight, no Runner overhead)
    # Options:
    #   background: true - Run in background thread (returns immediately)
    def perform(background: false)
      _evaluate_pipeline_blocks!

      if background
        @_background_thread = Thread.new do
          @_minigun_task.root_pipeline.run(self)
        rescue StandardError => e
          warn "Background task error: #{e.message}"
          warn e.backtrace.join("\n")
        end

        sleep 0.1
        puts "Task running in background (Thread ##{@_background_thread.object_id})"
        puts 'Use task.hud to open the HUD monitor'
        self
      else
        @_minigun_task.root_pipeline.run(self)
      end
    end

    # Open HUD monitor for running pipeline
    # Only works if task is running in background
    def hud
      _evaluate_pipeline_blocks! unless @_pipeline_blocks_evaluated

      unless @_minigun_task
        raise 'Task not initialized. Run task.run(background: true) first.'
      end

      pipeline = @_minigun_task.root_pipeline

      unless pipeline.instance_variable_get(:@stats)
        raise 'Pipeline stats not initialized. Make sure task is running with task.run(background: true)'
      end

      # Launch HUD (blocks until user quits)
      Minigun::HUD.launch(pipeline)
    end

    # Stop background execution
    def stop
      if @_background_thread&.alive?
        @_background_thread.kill
        @_background_thread.join(1)
        puts 'Background task stopped'
      else
        puts 'No background task running'
      end
    end

    # Check if task is running in background
    def running?
      @_background_thread&.alive? || false
    end

    # Wait for background task to complete
    def wait
      if @_background_thread
        @_background_thread.join
        puts 'Background task completed'
      else
        puts 'No background task to wait for'
      end
    end

    alias_method :join, :wait

    # Start the task in a background thread
    # Alias for run(background: true)
    def start
      run(background: true)
    end

    # Convenience aliases
    alias_method :go_brr!, :run        # Fun production alias
    alias_method :go_brrr!, :run
    alias_method :go_brrrr!, :run
    alias_method :go_brrrrr!, :run
    alias_method :execute, :perform    # Formal direct execution alias
  end
end
