# frozen_string_literal: true

module Minigun
  module Stages
    # Base class for all pipeline stages
    class Base
      include Minigun::HooksMixin
      
      # Register stage-specific hook points
      register_hook_points :start, :finish, :error, :process

      attr_reader :name, :job_id, :pipeline, :task, :context, :options, :queues
      attr_accessor :block, :inputs, :outputs

      def initialize(name, pipeline, options = {})
        @name = name.to_sym
        @pipeline = pipeline
        @task = pipeline.task
        @context = pipeline.context
        @options = options
        @instance_context = @context

        # Set up stage connections
        @inputs = []
        @outputs = []

        # Configure thread count
        @threads = options[:threads] || 1
        @thread_pool = nil
        @worker_threads = []

        # Set stage status
        @running = false
        
        # Set up logger
        @logger = Logger.new($stdout)
        @logger.level = Logger::INFO

        # Configure queue processing
        @queues = options[:queues] || [:default]
        
        # Set up job ID from pipeline
        @job_id = pipeline.job_id
        
        # Set up counters
        @processed_count = 0
        @emitted_count = 0
        @emitted_items = []
      end

      # Process a single item (to be implemented by subclasses)
      def process(item)
        raise NotImplementedError, "#{self.class} must implement #process"
      end

      # Send an item to downstream stages
      def emit(item, queue = :default)
        # Skip nil items
        return if item.nil?

        # Track emitted items
        @emitted_items << item
        
        # Track emit count in fork context if we're in a fork
        if Thread.current[:minigun_fork_context]
          Thread.current[:minigun_fork_context][:emitted_items] ||= []
          Thread.current[:minigun_fork_context][:emitted_items] << item
        end

        # Increment emit counter
        @emitted_count += 1

        # Send to next stages
        send_to_next_stage(item, queue)
      end

      # Send an item to a specific queue
      def emit_to_queue(queue, item)
        # Track emitted items
        @emitted_items << item
        
        # Track emit count in fork context if we're in a fork
        if Thread.current[:minigun_fork_context]
          Thread.current[:minigun_fork_context][:emitted_items] ||= []
          Thread.current[:minigun_fork_context][:emitted_items] << item
        end

        # Increment emit counter
        @emitted_count += 1

        # Send the item to the specified queue
        queue = queue.to_sym
        send_to_next_stage(item, queue)
      end

      # Add an input stage
      def add_input(stage)
        @inputs << stage unless @inputs.include?(stage)
      end

      # Add an output stage
      def add_output(stage)
        @outputs << stage unless @outputs.include?(stage)
        stage.add_input(self) if stage.respond_to?(:add_input)
      end

      # Start the stage
      def start
        return if @running
        
        @running = true
        
        # Run hooks before starting
        run_hook :start, @name, @context do
          # Start the stage
          on_start

          # Leave the actual execution to subclasses
        end
      end

      # Stop the stage
      def stop
        @running = false
      end

      # Wait for the stage to finish
      def join
        # Default implementation - subclasses should override as needed
      end

      # Get stage status
      def running?
        @running
      end

      # Called when stage starts
      def on_start
        @logger.info("[Minigun:#{@job_id}][#{@name}] Stage starting")
      end

      # Called when stage finishes
      def on_finish
        # Run finish hook
        run_hook :finish, @name, @context do
          @logger.info("[Minigun:#{@job_id}][#{@name}] Stage finished")
        end
      end

      # Called when stage encounters an error
      def on_error(error)
        # Run error hook
        run_hook :error, @name, error, @context do
          @logger.error("[Minigun:#{@job_id}][#{@name}] Error: #{error.message}")
          @logger.error(error.backtrace.join("\n")) if error.backtrace
        end
      end

      private

      # Send an item to all downstream stages that subscribe to the given queue
      def send_to_next_stage(item, queue = :default)
        # Get all output stages
        @outputs.each do |output_stage|
          # Check if this stage subscribes to the given queue
          if output_stage.queues && output_stage.queues.include?(queue)
            # Send the item to the stage
            output_stage.process(item) if output_stage.respond_to?(:process)
          end
        end
      end
    end
  end
end
