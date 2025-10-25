# frozen_string_literal: true

module Minigun
  # The Task class manages the configuration and execution of Minigun tasks
  class Task
    include Minigun::HooksMixin

    # Register standard Minigun hook points
    register_hook_points :run, :stage, :fork, :finished

    attr_reader :config, :pipeline, :connections, :queue_subscriptions, :accumulated_items
    attr_accessor :pipeline_definition

    # Compatibility method for tests that expect a hooks hash
    def hooks
      @hooks_cache ||= begin
        hooks_hash = {}

        # Convert the new hook structure to the old format
        [:run, :stage, :fork, :finished].each do |point|
          hooks_data = self.class.get_hooks(point)
          [:before, :after, :around].each do |type|
            hook_name = "#{type}_#{point}".to_sym
            hook_array = hooks_data[type] || []
            # Convert Proc objects to the format tests expect
            hooks_hash[hook_name] = hook_array.map { |h| h.is_a?(Hash) ? h : { block: h } }
          end
        end

        hooks_hash
      end
    end

    # Compatibility method for stage blocks
    def stage_blocks
      return {} unless @stage_blocks

      # Convert new format to old format for backward compatibility
      result = {}
      @stage_blocks.each do |name, data|
        if data.is_a?(Hash)
          # New format: { type: :processor, block: proc, options: {} }
          result[name] = data[:block]
        else
          # Old format: just a proc
          result[name] = data
        end
      end
      result
    end

    # Compatibility method for tests
    def stage_blocks=(blocks)
      @stage_blocks = {}
      blocks.each do |name, block|
        @stage_blocks[name] = { type: :processor, block: block, options: {} }
      end
    end

    def initialize
      # Initialize configuration with defaults
      @config = {
        max_threads: 2,
        max_processes: 2,
        max_retries: 3,
        batch_size: 100,
        fork_mode: :auto,
        fork_type: :ipc,
        accumulator_max_queue: 1000,
        accumulator_max_all: 5000,
        accumulator_check_interval: 0.1,
        logger: Logger.new(STDOUT)
      }

      # Initialize pipeline components
      @pipeline = []
      @connections = {}
      @stage_blocks = {}
      @pipeline_definition = nil
      @queue_subscriptions = {}
      @accumulated_items = []

      # Clear any existing hooks and cache
      self.class.clear_hooks
      @hooks_cache = nil
    end

    # Generic method to add a stage of any type
    def add_stage(type, name = :default, options = {}, &block)
      # Process connection options
      options = process_connection_options(name, options)

      # Apply stage-specific configurations
      options = apply_stage_configs(type, options)

      # Store the block for later execution
      @stage_blocks[name] = { type: type, block: block, options: options }

      # Convert the type for pipeline storage
      pipeline_type = case type
                     when :processor
                       :processor
                     else
                       type
                     end

      pipeline_entry = {
        type: pipeline_type,
        name: name,
        options: options,
        block: block
      }

      # Add from/to if they exist in the connections
      if @connections.key?(name)
        pipeline_entry[:to] = @connections[name]
      end

      # Find sources that connect to this stage
      @connections.each do |source, targets|
        if targets.include?(name)
          pipeline_entry[:from] ||= []
          pipeline_entry[:from] = source if pipeline_entry[:from].is_a?(Array) && pipeline_entry[:from].empty?
          pipeline_entry[:from] << source if pipeline_entry[:from].is_a?(Array) && !pipeline_entry[:from].include?(source)
          pipeline_entry[:from] = [pipeline_entry[:from]] if !pipeline_entry[:from].is_a?(Array) && pipeline_entry[:from] != source
          pipeline_entry[:from] << source if pipeline_entry[:from].is_a?(Array) && !pipeline_entry[:from].include?(source)
        end
      end

      # Add to pipeline array
      @pipeline << pipeline_entry

      # For backward compatibility, create default linear connections if not explicitly specified
      if @pipeline.size > 1 && !options[:from] && !options[:to]
        previous_stage = @pipeline[-2][:name]
        @connections[previous_stage] ||= []
        @connections[previous_stage] << name unless @connections[previous_stage].include?(name)

        # Also update the pipeline entry for from/to references
        @pipeline[-1][:from] = previous_stage
        @pipeline[-2][:to] ||= []
        @pipeline[-2][:to] = [name] if @pipeline[-2][:to].empty?
        @pipeline[-2][:to] << name unless @pipeline[-2][:to].include?(name)
      end
    end

    # Process a connection option to determine where to send output
    def process_connection_options(name, options)
      # Extract connection options
      from = options.delete(:from)
      to = options.delete(:to)
      queues = options.delete(:queues)

      # Record "from" connection if specified
      if from
        source_names = from.is_a?(Array) ? from : [from]
        source_names.each do |source_name|
          @connections[source_name] ||= []
          @connections[source_name] << name unless @connections[source_name].include?(name)
        end
      end

      # Record "to" connection if specified
      if to
        target_names = to.is_a?(Array) ? to : [to]
        @connections[name] = target_names
      end

      # Record queue subscriptions
      # If queues specified, use them; otherwise default to [:default]
      if queues
        @queue_subscriptions[name] = Array(queues).map(&:to_sym)
      else
        @queue_subscriptions[name] = [:default]
      end

      # Return the processed options
      options
    end

    # Define a processor block that transforms items
    def add_processor(name = :default, options = {}, &block)
      add_stage(:processor, name, options, &block)
    end
    alias add_consumer add_processor

    # Define a specialized accumulator stage
    def add_accumulator(name = :default, options = {}, &block)
      # Automatically define flush if not already defined in options
      options[:flush] ||= proc do |accum|
        if accum[:items] && accum[:items].size >= @config[:batch_size]
          true
        else
          false
        end
      end
      add_stage(:accumulator, name, options, &block)
    end

    # Add a COW fork stage (uses copy-on-write fork)
    def add_cow_fork(name = :default, options = {}, &block)
      options[:forking] = :cow
      add_stage(:processor, name, options, &block)
    end

    # Add an IPC fork stage (uses message-passing fork)
    def add_ipc_fork(name = :default, options = {}, &block)
      options[:forking] = :ipc
      add_stage(:processor, name, options, &block)
    end

    # Define hooks with options similar to ActionController
    def add_hook(name, options = {}, &block)
      hook_type, hook_point = extract_hook_info(name)

      case hook_type
      when :before
        self.class.before(hook_point, &block)
      when :after
        self.class.after(hook_point, &block)
      when :around
        self.class.around(hook_point, &block)
      end

      # Clear hooks cache so it rebuilds
      @hooks_cache = nil
    end

    # Run the defined task for the given context
    def run(context)
      validate_configuration!

      # If a custom pipeline is defined, use it
      if @pipeline_definition || @pipeline.any?
        run_custom_pipeline(context)
      else
        # Otherwise, use the simple emitter-processor pattern
        run_simple_pipeline(context)
      end
    end

    # Run all hooks of a specific type
    def run_hooks(type, context, *args)
      hook_type, hook_point = extract_hook_info(type)

      # Create a context for running the hook
      if block_given?
        run_hook(hook_point, *args) { yield }
      else
        # Just run the before or after hooks without a block
        case hook_type
        when :before
          hooks = self.class.get_hooks(hook_point)
          (hooks[:before] || []).each { |hook| execute_hook(hook, args) }
        when :after
          hooks = self.class.get_hooks(hook_point)
          (hooks[:after] || []).each { |hook| execute_hook(hook, args) }
        end
      end
    end

    private

    # Extract hook type and point from legacy hook name
    def extract_hook_info(name)
      name = name.to_s
      if name.start_with?('before_')
        [:before, name.sub('before_', '').to_sym]
      elsif name.start_with?('after_')
        [:after, name.sub('after_', '').to_sym]
      elsif name.start_with?('around_')
        [:around, name.sub('around_', '').to_sym]
      elsif name.start_with?('on_stage_error_')
        [:after, :stage_error]
      else
        [:before, name.to_sym]
      end
    end

    # Apply stage-specific configurations
    def apply_stage_configs(type, options)
      case type
      when :processor
        options[:max_retries] ||= @config[:max_retries]
        options[:max_threads] ||= @config[:max_threads]
      when :accumulator
        options[:max_queue] ||= @config[:accumulator_max_queue]
        options[:max_all] ||= @config[:accumulator_max_all]
        options[:check_interval] ||= @config[:accumulator_check_interval]
      end
      options
    end

    # Validate configuration settings
    def validate_configuration!
      # Skip validation if we have a pipeline definition since it will be built dynamically
      return if @pipeline_definition

      # Basic validation logic
      # For COW processor, ensure there's an accumulator before it
      if @config[:fork_type] == :cow &&
         @pipeline.any? { |stage| stage[:type] == :processor }
        has_accumulator = false
        @pipeline.each do |stage|
          if stage[:type] == :accumulator
            has_accumulator = true
          elsif stage[:type] == :processor && !has_accumulator
            raise Minigun::Error, 'COW processor type requires an accumulator stage before it'
          end
        end
      end
    end

    # Run a custom pipeline
    def run_custom_pipeline(context)
      # If we have a pipeline definition, execute it to build the pipeline
      if @pipeline_definition.respond_to?(:call) && @pipeline.empty?
        @pipeline_definition.call(self)
      end

      # Create and run the pipeline
      pipeline = Minigun::Pipeline.new(self, context)
      pipeline.run
    end

    # Run a simple processor pipeline
    def run_simple_pipeline(context)
      # Create a runner instance
      runner = Minigun::Runner.new(context)

      # Run the pipeline with hooks
      run_hook :run, context do
        runner.run
      end
    end
  end
end
