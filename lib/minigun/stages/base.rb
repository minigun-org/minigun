# frozen_string_literal: true

require 'logger'
require 'forwardable'

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
        @task = pipeline.task
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
        # Check the arity of send_to_next_stage to support both old and new interfaces
        send_method = @pipeline.method(:send_to_next_stage)
        if send_method.arity == 2
          @pipeline.send_to_next_stage(self, item)
        else
          @pipeline.send_to_next_stage(self, item, queue)
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
        
        # Send to specified queue
        @pipeline.send_to_next_stage(self, item, queue.to_sym)
      end
      
      # Alias for emit_to_queue
      alias_method :enqueue, :emit_to_queue

      # Called when the stage is starting
      def on_start
        @logger.info "[Minigun:#{@job_id}][#{name}] Stage starting"
        
        # Execute before hooks
        hook_name = "before_#{name}".to_sym
        if @task.class.respond_to?(:_minigun_hooks) && @task.class._minigun_hooks[hook_name].is_a?(Array)
          @task.class._minigun_hooks[hook_name].each do |hook|
            if hook_should_run?(hook)
              @task.instance_exec(&hook[:block]) if hook[:block]
            end
          end
        end
      end

      # Called when the stage is finishing
      def on_finish
        @logger.info "[Minigun:#{@job_id}][#{name}] Stage finished"
        
        # Execute after hooks
        hook_name = "after_#{name}".to_sym
        if @task.class.respond_to?(:_minigun_hooks) && @task.class._minigun_hooks[hook_name].is_a?(Array)
          @task.class._minigun_hooks[hook_name].each do |hook|
            if hook_should_run?(hook)
              @task.instance_exec(&hook[:block]) if hook[:block]
            end
          end
        end
      end

      # Called when a stage encounters an error
      def on_error(error)
        @logger.error "[Minigun:#{@job_id}][#{name}] Error: #{error.message}"
        @logger.error error.backtrace.join("\n") if error.backtrace
        
        # Execute error hooks
        hook_name = "on_error_#{name}".to_sym
        if @task.class.respond_to?(:_minigun_hooks) && @task.class._minigun_hooks[hook_name].is_a?(Array)
          @task.class._minigun_hooks[hook_name].each do |hook|
            if hook_should_run?(hook)
              @task.instance_exec(error, &hook[:block]) if hook[:block]
            end
          end
        end
      end

      private

      def register_hooks
        return unless @task.respond_to?(:_minigun_hooks)

        # Register stage-specific hooks if task has them
        [:before_stage, :after_stage, :on_stage_error].each do |hook_type|
          stage_hook = :"#{hook_type}_#{@name.to_s.gsub(/\s+/, '_').downcase}"
          if @task._minigun_hooks[stage_hook]
            @hooks ||= {}
            @hooks[hook_type] = @task._minigun_hooks[stage_hook]
          end
        end
      end

      def call_hooks(hook_type, *args)
        return unless @hooks && @hooks[hook_type]
        
        @hooks[hook_type].each do |hook_config|
          next unless hook_should_run?(hook_config)
          @task.instance_exec(*args, &hook_config[:block]) if hook_config[:block]
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
              @task.instance_exec(&condition)
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
              @task.instance_exec(&condition)
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
