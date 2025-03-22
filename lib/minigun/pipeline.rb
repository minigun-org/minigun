# frozen_string_literal: true

require 'securerandom'
require 'concurrent'
require 'forwardable'

module Minigun
  # Orchestrates the flow of items through stages
  class Pipeline
    extend Forwardable
    def_delegators :@logger, :info, :warn, :error, :debug

    attr_reader :task, :job_id, :stages

    def initialize(task, options = {})
      @task = task
      @logger = options[:logger] || Logger.new($stdout)
      @job_id = options[:job_id] || SecureRandom.hex(4)

      # Get config from options or from task class if available
      @config = options[:config] ||
                (task.class.respond_to?(:_minigun_config) ? task.class._minigun_config : {})

      # Set default configuration options
      @config[:max_processes] ||= 2
      @config[:max_threads] ||= 5
      @config[:max_retries] ||= 3
      @config[:fork_mode] ||= :ipc

      # Initialize empty collections
      @stages = {}
      @queues = {}
      @results = {}

      # Build pipeline
      return unless @config[:custom] || false

      build_pipeline_from_task_definition
    end

    # Add a stage to the pipeline
    def add_stage(stage_class, name, options = {})
      # Create the stage instance
      stage = stage_class.new(name, self, options.merge(logger: @logger))

      # Add to stages array
      @stages[name] = {
        name: name,
        instance: stage,
        type: stage_class.name.split('::').last.downcase.to_sym,
        input_connections: [],
        output_connections: []
      }

      stage
    end

    # Connect stages with explicit from/to relationships
    def connect_stages
      # Initialize queues if needed
      @queues ||= {}

      # Get connections from task
      connections = if @task.class.respond_to?(:_minigun_connections)
                      @task.class._minigun_connections
                    else
                      {}
                    end
      queue_subscriptions = if @task.class.respond_to?(:_minigun_queue_subscriptions)
                              @task.class._minigun_queue_subscriptions
                            else
                              {}
                            end

      if connections && !connections.empty?
        # Create explicit connections based on from/to relationships
        connections.each do |from_stage, to_stages|
          to_stages = [to_stages] unless to_stages.is_a?(Array)

          to_stages.each do |to_stage|
            queue_name = "#{from_stage}_to_#{to_stage}"
            @queues[queue_name] ||= Queue.new
            @logger.debug "Connected #{from_stage} → #{to_stage} via queue #{queue_name}"
          end
        end
      else
        # Default linear pipeline - connect each stage to the next
        stage_names = @stages.keys
        (0...stage_names.length - 1).each do |i|
          from_stage = stage_names[i]
          to_stage = stage_names[i + 1]
          queue_name = "#{from_stage}_to_#{to_stage}"
          @queues[queue_name] ||= Queue.new
          @logger.debug "Connected #{from_stage} → #{to_stage} via queue #{queue_name}"
        end
      end

      # Process queue subscriptions for fan-out/fan-in
      return unless queue_subscriptions && !queue_subscriptions.empty?

      queue_subscriptions.each do |queue_name, subscribers|
        subscribers.each do |stage_name|
          @queues[queue_name] ||= Queue.new
          @logger.debug "Subscribed #{stage_name} to queue #{queue_name}"
        end
      end
    end

    # Run the pipeline
    def run
      info("[Minigun:#{@job_id}] Starting pipeline execution")

      # Run before hooks
      @task.run_hooks(:before_run)

      # Validate the pipeline
      validate_pipeline

      # Create queues between stages if needed
      create_stage_queues if @queues.empty?

      # Populate stage input/output queues
      connect_stages if @config[:custom]

      # Start all stages except producers
      @stages.each_value do |stage_info|
        next if stage_info[:instance].respond_to?(:stage_role) && stage_info[:instance].stage_role == :producer

        stage_info[:instance].run if stage_info[:instance].respond_to?(:run)
      end

      # Run producers - these will generate items
      producer_futures = []
      @stages.each do |stage_name, stage_info|
        next unless stage_info[:instance].respond_to?(:stage_role) && stage_info[:instance].stage_role == :producer

        future = Concurrent::Future.execute do
          stage_info[:instance].run
        rescue StandardError => e
          error("[Minigun:#{@job_id}] Producer #{stage_name} failed: #{e.message}")
          error("[Minigun:#{@job_id}] #{e.backtrace.join("\n")}") if e.backtrace
          raise e
        end
        producer_futures << future
      end

      # Wait for producers to finish
      producer_futures.each(&:wait)

      # Check for producer errors
      producer_futures.each do |future|
        if future.rejected?
          error("[Minigun:#{@job_id}] Pipeline failed due to producer error: #{future.reason.message}")
          raise future.reason
        end
      end

      # Mark all queues as done
      # We can't use "close" on Concurrent::Array, so we'll track done state separately
      @queues.each_key do |queue_name|
        # Set a marker that this queue is done producing
        @queues_done ||= {}
        @queues_done[queue_name] = true
      end

      # Wait for all stages to finish processing
      shutdown_stages

      # Run after hooks
      @task.run_hooks(:after_run)

      info("[Minigun:#{@job_id}] Pipeline execution completed")
    end

    # Send an item to the next stage
    def send_to_next_stage(from_stage, item, queue = :default)
      # Find the stage in our stages array
      stage_info = @stages[from_stage]
      return if stage_info.nil?

      # Check if we're using explicit connections (custom pipeline)
      if @config[:custom] && !@queues.empty? && queue != :default
        # Queue-based routing - send to all stages that subscribe to this queue
        @queues[queue]&.each do |target_stage|
          # Use the queue between these stages
          queue_name = "#{from_stage}_to_#{target_stage}"
          @queues[queue_name] ||= Queue.new

          @queues[queue_name].push(item)

          debug("[Minigun:#{@job_id}] Sent item from #{from_stage} to #{target_stage} via queue #{queue}")
        end
      elsif @config[:custom] && stage_info[:output_connections].any?
        # Send to all connected output stages
        stage_info[:output_connections].each do |connection|
          connection[:queue].push(item)

          debug("[Minigun:#{@job_id}] Sent item from #{from_stage} to #{connection[:target]}")
        end
      elsif stage_info[:output_queue]
        # Send to the sequential next stage
        stage_info[:output_queue].push(item)

        debug("[Minigun:#{@job_id}] Sent item from #{from_stage} to next stage")
      end
    end

    # Create queues between stages for a simple sequential pipeline
    def create_stage_queues
      @stages.each_with_index do |stage_name, i|
        # Skip the last stage, it doesn't need an output queue
        next if i == @stages.length - 1

        # Create a queue for this stage's output
        queue = Queue.new
        @stages[stage_name][:output_queue] = queue

        # Set the next stage's input queue
        next_stage = @stages[stage_name][:output_connections].first[:target]
        @stages[next_stage][:input_queue] = queue
      end
    end

    private

    # Build pipeline from task definition
    def build_pipeline_from_task_definition
      # First, if we have a pipeline definition block and the pipeline isn't already populated
      if @task.class._minigun_pipeline_definition && @task.class._minigun_pipeline.empty?
        # The pipeline definition needs to be executed in the context of the class
        # However, we've already defined our block to handle instance variables
        # So we'll evaluate it in the task instance context, but we need to make sure
        # the DSL methods are available for it to call

        # Define temporary producer/processor/etc. methods on the task instance
        # that delegate to the class versions
        task_class = @task.class

        # Define temporary DSL methods
        dsl_methods = %i[producer processor accumulator consumer cow_fork ipc_fork]

        # Save original methods if they exist and define temporary ones
        original_methods = {}
        dsl_methods.each do |method_name|
          original_methods[method_name] = @task.method(method_name) if @task.respond_to?(method_name)

          # Define a method on the instance that delegates to the class
          @task.define_singleton_method(method_name) do |*args, &block|
            task_class.send(method_name, *args, &block)
          end
        end

        # Also define emit and emit_to_queue methods on the task instance
        # to capture emissions during pipeline setup - these temporary methods
        # will capture the emissions during pipeline definition
        current_stage = nil
        emission_captures = []

        @task.define_singleton_method(:emit) do |item|
          return unless current_stage

          # Track the emission for later replay
          emission_captures << { stage: current_stage, item: item, queue: :default }
        end

        @task.define_singleton_method(:emit_to_queue) do |queue, item|
          return unless current_stage

          # Track the emission for later replay
          emission_captures << { stage: current_stage, item: item, queue: queue }
        end

        begin
          # Now evaluate the pipeline definition block in the task instance context
          @task.instance_eval(&@task.class._minigun_pipeline_definition)
        ensure
          # Restore original methods if they existed
          (dsl_methods + %i[emit emit_to_queue]).each do |method_name|
            @task.singleton_class.remove_method(method_name)
            @task.define_singleton_method(method_name, original_methods[method_name]) if original_methods[method_name]
          end
        end
      end

      # Create stages in the order they were defined
      @task.class._minigun_pipeline.each do |stage_info|
        # Map stage types to appropriate classes
        stage_type = stage_info[:type]
        stage_options = stage_info[:options] || {}

        # Use Processor for all stage types except accumulator,
        # stage_role in options determines behavior
        stage_class = if stage_type == :accumulator
                        Minigun::Stages::Accumulator
                      else
                        Minigun::Stages::Processor
                      end

        add_stage(stage_class, stage_info[:name], stage_options)
      end
    end

    # Validate the pipeline structure, including check that COW consumers come after accumulators
    def validate_pipeline
      # Collect all COW consumers
      @stages.each do |stage_name, stage_info|
        stage = stage_info[:instance]

        # Check if this is a COW consumer
        if stage.is_a?(Stages::Processor) &&
           stage.stage_role == :consumer &&
           stage.instance_variable_defined?(:@fork_impl) &&
           stage.instance_variable_get(:@fork_impl).is_a?(Stages::CowFork)

          if @config[:custom]
            has_accumulator_input = false

            # Check if any input is from an accumulator
            if stage_info[:input_connections]&.any?
              stage_info[:input_connections].each do |connection|
                from_stage = @stages[connection[:from_stage]]
                if from_stage && from_stage[:instance].is_a?(Stages::Accumulator)
                  has_accumulator_input = true
                  break
                end
              end
            end

            unless has_accumulator_input
              stage_name = stage.name
              error("[Minigun:#{@job_id}] COW consumer '#{stage_name}' must have an accumulator as input")
              raise Minigun::Error, "COW consumer '#{stage_name}' must have an accumulator as input"
            end
          # For sequential pipelines, check the previous stage
          elsif stage_info[:input_connections]&.any?
            # Get the previous stage
            prev_stage = @stages[stage_name][:input_connections].first[:from_stage]
            unless @stages[prev_stage][:instance].is_a?(Stages::Accumulator)
              error("[Minigun:#{@job_id}] COW consumer '#{stage_name}' must come after an accumulator stage")
              raise Minigun::Error, "COW consumer '#{stage_name}' must come after an accumulator stage"
            end
          else
            error("[Minigun:#{@job_id}] COW consumer '#{stage_name}' must come after an accumulator stage")
            raise Minigun::Error, "COW consumer '#{stage_name}' must come after an accumulator stage"
          end
        end
      end
    end

    def shutdown_stages
      # Shutdown all stages, collect statistics
      stage_stats = {}

      @stages.each do |stage_name, stage_info|
        next unless stage_info[:instance].respond_to?(:shutdown)

        begin
          result = stage_info[:instance].shutdown
          stage_stats[stage_name] = result if result.is_a?(Hash)

          info("[Minigun:#{@job_id}] Stage #{stage_name} shutdown complete")
        rescue StandardError => e
          error("[Minigun:#{@job_id}] Error shutting down #{stage_name}: #{e.message}")
          error(e.backtrace.join("\n")) if e.backtrace
        end
      end

      # Print overall statistics
      return unless stage_stats.any?

      info("[Minigun:#{@job_id}] Pipeline statistics:")
      stage_stats.each do |stage_name, stats|
        info("[Minigun:#{@job_id}] - #{stage_name}: #{stats.inspect}")
      end
    end
  end
end
