# frozen_string_literal: true

module Minigun
  module Stages
    # Base class for all stages in a Minigun pipeline
    class Base
      extend Forwardable
      def_delegators :@logger, :info, :warn, :error, :debug

      attr_reader :name, :config

      def initialize(name, pipeline, config = {})
        @name = name
        @pipeline = pipeline
        @config = config
        @logger = config[:logger] || Logger.new($stdout)
        @context = pipeline.context

        # Get the task from the pipeline or context
        @task = if pipeline.respond_to?(:task)
                  pipeline.task
                elsif @context.is_a?(Minigun::Task)
                  @context
                elsif @context.class.respond_to?(:_minigun_task)
                  @context.class._minigun_task
                else
                  # Fallback to a new task
                  Minigun::Task.new
                end

        @job_id = pipeline.job_id

        # Register hooks if provided
        register_hooks
      end

      # Process a single item
      def process(item)
        raise NotImplementedError, "#{self.class} must implement #process"
      end

      # Send an item to the next stage(s) in the pipeline
      def emit(item, queue = :default)
        # Check if pipeline has the new method
        if @pipeline.respond_to?(:downstream_stages)
          send_to_next_stage(item, queue)
        else
          # Fall back to older interface
          send_method = @pipeline.method(:send_to_next_stage)
          if send_method.arity == 2
            @pipeline.send_to_next_stage(self, item)
          else
            @pipeline.send_to_next_stage(self, item, queue)
          end
        end
      end

      # Send an item to a specific queue
      def emit_to_queue(queue, item)
        # Track emit count in fork context if we're in a fork
        if Thread.current[:minigun_fork_context]
          Thread.current[:minigun_fork_context][:emit_count] ||= 0
          Thread.current[:minigun_fork_context][:emit_count] += 1
          Thread.current[:minigun_fork_context][:success_count] ||= 0
          Thread.current[:minigun_fork_context][:success_count] += 1
        end

        # Send to specified queue using the new method if available
        if @pipeline.respond_to?(:downstream_stages)
          send_to_next_stage(item, queue.to_sym)
        else
          # Fall back to old method
          @pipeline.send_to_next_stage(self, item, queue.to_sym)
        end
      end

      # Alias for emit_to_queue
      alias_method :enqueue, :emit_to_queue

      # Called when the stage is starting
      def on_start
        @logger.info "[Minigun:#{@job_id}][#{name}] Stage starting"

        # Execute before hooks
        hook_name = :"before_#{name}"
        return unless @task.hooks && @task.hooks[hook_name].is_a?(Array)

        @task.hooks[hook_name].each do |hook|
          @context.instance_exec(&hook[:block]) if hook_should_run?(hook) && hook[:block]
        end
      end

      # Called when the stage is finishing
      def on_finish
        @logger.info "[Minigun:#{@job_id}][#{name}] Stage finished"

        # Execute after hooks
        hook_name = :"after_#{name}"
        return unless @task.hooks && @task.hooks[hook_name].is_a?(Array)

        @task.hooks[hook_name].each do |hook|
          @context.instance_exec(&hook[:block]) if hook_should_run?(hook) && hook[:block]
        end
      end

      # Called when a stage encounters an error
      def on_error(error)
        @logger.error "[Minigun:#{@job_id}][#{name}] Error: #{error.message}"
        @logger.error error.backtrace.join("\n") if error.backtrace

        # Execute error hooks
        hook_name = :"on_error_#{name}"
        return unless @task.hooks && @task.hooks[hook_name].is_a?(Array)

        @task.hooks[hook_name].each do |hook|
          @context.instance_exec(error, &hook[:block]) if hook_should_run?(hook) && hook[:block]
        end
      end

      private

      # Send an item to the next stage(s) based on the pipeline connections
      def send_to_next_stage(item, queue = :default)
        # Find downstream stages connected to this stage
        downstream = @pipeline.downstream_stages(@name)

        # If no downstream stages, do nothing
        return if downstream.empty?

        # Get queue subscriptions for each stage
        downstream.each do |stage|
          # Check if this stage is subscribed to the emitted queue
          subscriptions = @pipeline.queue_subscriptions(stage.name)

          # If stage subscribed to default queue or specifically to this queue, forward the item
          next unless subscriptions.include?(:default) || subscriptions.include?(queue)

          begin
            stage.process(item)
          rescue StandardError => e
            @logger.error "[Minigun:#{@job_id}][#{@name}] Error sending to #{stage.name}: #{e.message}"
            @logger.error e.backtrace.join("\n") if e.backtrace
            stage.on_error(e) if stage.respond_to?(:on_error)
          end
        end
      end

      # Register hooks for this stage
      def register_hooks
        # Register stage-specific hooks if task has them
        %i[before_stage after_stage on_stage_error].each do |hook_type|
          stage_hook = :"#{hook_type}_#{@name.to_s.gsub(/\s+/, '_').downcase}"
          if @task.hooks[stage_hook]
            @hooks ||= {}
            @hooks[hook_type] = @task.hooks[stage_hook]
          end
        end
      end

      def call_hooks(hook_type, *args)
        return unless @hooks && @hooks[hook_type]

        @hooks[hook_type].each do |hook_config|
          next unless hook_should_run?(hook_config)

          @context.instance_exec(*args, &hook_config[:block]) if hook_config[:block]
        end
      end

      # Check if a hook should run based on its config
      def hook_should_run?(hook)
        # No conditions means always run
        return true unless hook[:if] || hook[:unless]

        # Check if conditions
        if_result = true
        if hook[:if]
          if_conditions = [hook[:if]].flatten
          if_result = if_conditions.all? do |condition|
            if condition.is_a?(Proc)
              @context.instance_exec(&condition)
            else
              condition
            end
          end
        end

        # Check unless conditions
        unless_result = true
        if hook[:unless]
          unless_conditions = [hook[:unless]].flatten
          unless_result = unless_conditions.none? do |condition|
            if condition.is_a?(Proc)
              @context.instance_exec(&condition)
            else
              condition
            end
          end
        end

        # Both conditions must be true
        if_result && unless_result
      end
    end
  end
end
