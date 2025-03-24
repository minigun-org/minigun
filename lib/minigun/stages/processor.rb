# frozen_string_literal: true

module Minigun
  module Stages
    # Unified processor stage for all pipeline stages
    class Processor < Base
      # ResultWrapper class provides a simple wrapper for results that don't respond to wait
      ResultWrapper = Struct.new(:wait, :value)

      def initialize(name, pipeline, options = {})
        super
        @processed_count = Concurrent::AtomicFixnum.new(0)
        @fail_count = Concurrent::AtomicFixnum.new(0)
        @emitted_count = Concurrent::AtomicFixnum.new(0)
        @max_retries = options[:max_retries] || 3
        @threads = options[:threads] || options[:max_threads] || 5
        @processes = options[:processes] || options[:max_processes] || 2
        @batch_size = options[:batch_size] || 100

        @thread_pool = Concurrent::FixedThreadPool.new(@threads)

        # Get the block from the task
        @block = nil
        @block = @task.stage_blocks[name.to_sym] if @task.stage_blocks[name.to_sym]

        # Initialize fork implementation if needed
        fork_type = options[:fork] || options[:type]
        return unless %i[cow ipc].include?(fork_type)

        init_fork_implementation(fork_type)
      end

      # Process a single item by passing it to the stage block
      def process(item)
        return if item.nil?

        begin
          # Keep track of items processed
          @processed_count.increment
          
          # Process the item
          result = nil
          
          # First try running the processor block
          if @block
            result = execute_block(@block, item)
          end
          
          # Emit the result if it's not nil
          emit(result) unless result.nil?
          
        rescue => e
          # Increment the error counter
          @fail_count.increment
          
          # Log the error
          Minigun.logger.error("Error processing item in #{@name} stage: #{e.message}")
          Minigun.logger.error(e.backtrace.join("\n")) if e.backtrace
          
          # If we have retries left, retry
          if @max_retries > 0
            @max_retries -= 1
            Minigun.logger.info("Retrying #{@name} stage (#{@max_retries} retries left)")
            retry
          end
          
          # No retries left, raise the error if in test environment or if explicitly configured to
          if ENV['MINIGUN_ALLOW_EXCEPTIONS'] || (@task.respond_to?(:config) && @task.config.is_a?(Hash) && @task.config[:fork_mode] == :never)
            raise e
          end
        end
      end

      # Shutdown the processor stage
      def shutdown
        # Shut down the thread pool if it exists
        if @thread_pool
          @thread_pool.shutdown
          @thread_pool.wait_for_termination(30)
        end

        # Call on_finish hook
        on_finish

        # Return stats
        {
          processed: @processed_count.value,
          failed: @fail_count.value,
          emitted: @emitted_count.value
        }
      end

      # Run the stage
      def run
        # Run the on_start hook
        on_start
        
        # If this is a source or producer stage, run it immediately
        # to generate initial items for the pipeline
        if @name == :source || @name == :producer
          # Call the block with nil to generate items
          result = execute_block(@block, nil)
          emit(result) unless result.nil?
        end
        
        # Return the stage for method chaining
        self
      end

      private

      # Execute a processor block with the given context
      def execute_block(block, item)
        return nil unless block.respond_to?(:call)

        # Set up the execution context
        execution_context = @context

        # Handle DSL syntax if context is a PipelineDSL
        if defined?(Minigun::PipelineDSL) && execution_context.is_a?(Minigun::PipelineDSL)
          # Set the current stage in the DSL context
          execution_context.current_stage = @name
        end

        # Call the block with the appropriate arguments
        if block.arity == 1
          block.call(item)
        elsif block.arity == 2
          block.call(item, execution_context)
        else
          block.call
        end
      end

      # Initialize appropriate fork implementation based on type
      def init_fork_implementation(fork_type)
        case fork_type
        when :cow
          # Get the module or class as a constant
          cow_implementation = Minigun::Stages.const_get(:CowFork)
          # Safely apply the implementation
          include_or_delegate(cow_implementation)
        when :ipc
          # Get the module or class as a constant
          ipc_implementation = Minigun::Stages.const_get(:IpcFork)
          # Safely apply the implementation
          include_or_delegate(ipc_implementation)
        end
      end
      
      # Include or delegate to the implementation based on the type
      def include_or_delegate(implementation)
        if implementation.is_a?(Module) && !implementation.is_a?(Class)
          # When it's a module (not a class), extend it
          extend implementation
        elsif implementation.is_a?(Class)
          # When it's a class, create an instance and delegate to it
          @fork_implementation = implementation.new(@name, @pipeline, @config)
          
          # Pass the block to the fork implementation directly
          # First try to use our own block
          if @block && @fork_implementation.instance_variable_defined?(:@stage_block)
            @fork_implementation.instance_variable_set(:@stage_block, @block)
          # If our block is nil, try to get it from the task
          elsif @task && @task.respond_to?(:stage_blocks) && 
                @task.stage_blocks[@name.to_sym] && 
                @fork_implementation.instance_variable_defined?(:@stage_block)
            @fork_implementation.instance_variable_set(:@stage_block, @task.stage_blocks[@name.to_sym])
          end
          
          # Define singleton methods that delegate to the implementation
          [:process, :shutdown].each do |method|
            if @fork_implementation.respond_to?(method)
              # Define a method that delegates to the implementation
              define_singleton_method(method) do |*args|
                @fork_implementation.send(method, *args)
              end
            end
          end
        end
      end
    end
  end
end
