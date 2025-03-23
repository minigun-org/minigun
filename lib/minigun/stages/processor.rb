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
        @failed_count = Concurrent::AtomicFixnum.new(0)
        @emitted_count = Concurrent::AtomicFixnum.new(0)

        # Set configuration with defaults
        @threads = options[:threads] || options[:max_threads] || 5
        @processes = options[:processes] || options[:max_processes] || 2
        @max_retries = options[:max_retries] || 3
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

      # Process a single item
      def process(item)
        # Process the item and emit result(s)
        result = execute_block(item)

        # Track processing
        @processed_count.increment

        # If result is not explicitly nil, emit it
        # This allows processors to filter by returning nil
        emit(result) unless result.nil?

        # Return the result
        result
      rescue StandardError => e
        @failed_count.increment
        error("[Minigun:#{@job_id}][Stage:#{@name}] Error processing item: #{e.class}: #{e.message}\n#{e.backtrace.join("\n")}")
        raise e
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
          failed: @failed_count.value,
          emitted: @emitted_count.value
        }
      end

      private

      # Execute the stage block with the given item
      def execute_block(item)
        # Create a context that includes the emit method
        execution_context = @context
        
        # If the context is a PipelineExecutor, set the current stage
        if execution_context.is_a?(Minigun::PipelineExecutor)
          execution_context.set_current_stage(self)
        # If the context doesn't respond to emit, create a wrapper that does
        elsif !execution_context.respond_to?(:emit)
          execution_wrapper = Object.new
          
          # Define emit method that delegates to the stage
          execution_wrapper.define_singleton_method(:emit) do |emitted_item, queue = :default|
            self.instance_variable_get(:@stage).emit(emitted_item, queue)
          end
          
          # Also add emit_to_queue as an alias
          execution_wrapper.define_singleton_method(:emit_to_queue) do |queue, emitted_item|
            self.instance_variable_get(:@stage).emit(emitted_item, queue)
          end
          
          # Store reference to the stage
          execution_wrapper.instance_variable_set(:@stage, self)
          
          # If we have an original context, delegate methods to it
          if @context
            # Define method_missing to delegate to original context
            execution_wrapper.define_singleton_method(:method_missing) do |method, *args, &block|
              if self.instance_variable_get(:@original_context).respond_to?(method)
                self.instance_variable_get(:@original_context).send(method, *args, &block)
              else
                super(method, *args, &block)
              end
            end
            
            # Define respond_to_missing? to properly handle method delegation
            execution_wrapper.define_singleton_method(:respond_to_missing?) do |method, include_private = false|
              self.instance_variable_get(:@original_context).respond_to?(method, include_private) || super(method, include_private)
            end
            
            # Store original context for delegation
            execution_wrapper.instance_variable_set(:@original_context, @context)
          end
          
          # Use our wrapper as the execution context
          execution_context = execution_wrapper
        end
        
        # Determine which block to use in priority order
        # 1. Try the directly assigned block
        if @block 
          block_to_execute = @block
          if block_to_execute.arity == 0
            # If block takes no arguments, make the item available as an instance variable
            execution_context.instance_exec do
              # Make the item available as an instance variable
              @item = item
              # Call the block directly
              block_to_execute.call
            end
          else
            # Otherwise call with the item as argument
            execution_context.instance_exec(item, &block_to_execute)
          end
        # 2. Try to find a block in the fork implementation
        elsif @fork_implementation && @fork_implementation.instance_variable_defined?(:@stage_block) && 
              @fork_implementation.instance_variable_get(:@stage_block)
          stage_block = @fork_implementation.instance_variable_get(:@stage_block)
          if stage_block.arity == 0
            execution_context.instance_exec do
              @item = item
              stage_block.call
            end
          else
            execution_context.instance_exec(item, &stage_block)
          end
        # 3. Check if block exists directly on the task for this stage
        elsif @task && @task.respond_to?(:stage_blocks) && @task.stage_blocks[@name.to_sym]
          stage_block = @task.stage_blocks[@name.to_sym]
          if stage_block.arity == 0
            execution_context.instance_exec do
              @item = item
              stage_block.call
            end
          else
            execution_context.instance_exec(item, &stage_block)
          end
        else
          # Default implementation just passes the item through
          item
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
