# frozen_string_literal: true

require 'set'

module Minigun
  # Pipeline represents a single data processing pipeline with stages
  # A Pipeline can be standalone or part of a multi-pipeline Task
  class Pipeline
    attr_reader :name, :config, :stages, :hooks, :dag, :input_queue, :output_queues, :stage_order, :stats

    def initialize(name, config = {})
      @name = name
      @config = {
        max_threads: config[:max_threads] || 5,
        max_processes: config[:max_processes] || 2,
        max_retries: config[:max_retries] || 3,
        use_ipc: config[:use_ipc] || false
      }

      @stages = {}  # { stage_name => Stage }

      # Pipeline-level hooks (run once per pipeline)
      @hooks = {
        before_run: [],
        after_run: [],
        before_fork: [],
        after_fork: []
      }

      # Stage-specific hooks (run per stage execution)
      @stage_hooks = {
        before: {},   # { stage_name => [blocks] }
        after: {},    # { stage_name => [blocks] }
        before_fork: {},
        after_fork: {}
      }

      @dag = DAG.new
      @stage_order = []

      # Statistics tracking
      @stats = nil  # Will be initialized in run()

      # For multi-pipeline communication
      @input_queues = []  # Array of input queues from upstream pipelines
      @output_queues = {}  # { pipeline_name => queue }
    end

    # Set an input queue for receiving items from upstream pipelines (backward compatibility)
    def input_queue=(queue)
      @input_queues << queue unless @input_queues.include?(queue)
    end

    # Get the input queues (returns array)
    def input_queues
      @input_queues
    end

    # Get the first input queue (backward compatibility)
    def input_queue
      @input_queues.first
    end

    # Add an input queue for receiving items from upstream pipelines
    def add_input_queue(queue)
      @input_queues << queue unless @input_queues.include?(queue)
    end

    # Add an output queue for sending items to a downstream pipeline
    def add_output_queue(pipeline_name, queue)
      @output_queues[pipeline_name] = queue
    end

    # Duplicate this pipeline for inheritance
    def dup
      new_pipeline = Pipeline.new(@name, @config.dup)

      # Copy stages hash (shallow copy - stages themselves are shared)
      new_pipeline.instance_variable_set(:@stages, @stages.dup)

      # Copy hooks (keep references to blocks)
      new_pipeline.instance_variable_set(:@hooks, {
        before_run: @hooks[:before_run].dup,
        after_run: @hooks[:after_run].dup,
        before_fork: @hooks[:before_fork].dup,
        after_fork: @hooks[:after_fork].dup
      })

      # Copy stage hooks
      new_pipeline.instance_variable_set(:@stage_hooks, {
        before: @stage_hooks[:before].transform_values(&:dup),
        after: @stage_hooks[:after].transform_values(&:dup),
        before_fork: @stage_hooks[:before_fork].transform_values(&:dup),
        after_fork: @stage_hooks[:after_fork].transform_values(&:dup)
      })

      # Duplicate the DAG with all nodes and edges
      new_dag = @dag.dup
      new_pipeline.instance_variable_set(:@dag, new_dag)
      new_pipeline.instance_variable_set(:@stage_order, @stage_order.dup)

      new_pipeline
    end

    # Add a stage to this pipeline
    def add_stage(type, name, options = {}, &block)
      # Extract routing information
      to_targets = options.delete(:to)
      if to_targets
        Array(to_targets).each { |target| @dag.add_edge(name, target) }
      end

      # Extract reverse routing (from:)
      from_sources = options.delete(:from)
      if from_sources
        Array(from_sources).each { |source| @dag.add_edge(source, name) }
      end

      # Extract inline hook procs (Option 3)
      if (before_proc = options.delete(:before))
        add_stage_hook(:before, name, &before_proc)
      end

      if (after_proc = options.delete(:after))
        add_stage_hook(:after, name, &after_proc)
      end

      if (before_fork_proc = options.delete(:before_fork))
        add_stage_hook(:before_fork, name, &before_fork_proc)
      end

      if (after_fork_proc = options.delete(:after_fork))
        add_stage_hook(:after_fork, name, &after_fork_proc)
      end

      # Create appropriate stage subclass
      stage = case type
              when :stage, :producer, :processor, :consumer
                AtomicStage.new(name: name, block: block, options: options)
              when :accumulator
                AccumulatorStage.new(name: name, block: block, options: options)
              else
                raise Minigun::Error, "Unknown stage type: #{type}"
              end

      # Store stage by name
      @stages[name] = stage

      # Add to stage order and DAG
      @stage_order << name
      @dag.add_node(name)
    end

    # Reroute stages by modifying the DAG
    def reroute_stage(from_stage, to:)
      # Remove existing outgoing edges from this stage
      old_targets = @dag.downstream(from_stage).dup
      old_targets.each do |target|
        @dag.instance_variable_get(:@edges)[from_stage].delete(target)
        @dag.instance_variable_get(:@reverse_edges)[target].delete(from_stage)
      end

      # Add new edges
      Array(to).each do |target|
        @dag.add_edge(from_stage, target)
      end
    end

    # Add a pipeline-level hook
    def add_hook(type, &block)
      @hooks[type] ||= []
      @hooks[type] << block
    end

    # Add a stage-specific hook
    def add_stage_hook(type, stage_name, &block)
      @stage_hooks[type] ||= {}
      @stage_hooks[type][stage_name] ||= []
      @stage_hooks[type][stage_name] << block
    end

    # Execute stage-specific hooks
    def execute_stage_hooks(type, stage_name)
      hooks = @stage_hooks.dig(type, stage_name) || []
      hooks.each { |h| @context.instance_exec(&h) }
    end

    # Run this pipeline
    def run(context)
      @context = context
      @job_start = Time.now
      @job_id ||= nil  # Job ID may be set by Runner

      # Initialize statistics tracking
      @stats = AggregatedStats.new(@name, @dag)
      @stats.start!

      log_info "#{log_prefix} Starting"

      # Build and validate DAG routing
      build_dag_routing!

      # Run before_run hooks
      @hooks[:before_run].each { |h| context.instance_eval(&h) }

      # Execute the pipeline
      run_pipeline(context)

      @job_end = Time.now
      @stats.finish!

      log_info "#{log_prefix} Finished in #{(@job_end - @job_start).round(2)}s"

      # Run after_run hooks
      @hooks[:after_run].each { |h| context.instance_eval(&h) }

      # Return produced count
      @stats.total_produced
    end

    # Main pipeline execution logic
    def run_pipeline(context)
      # Start internal queue (for stage-to-stage communication)
      @queue = SizedQueue.new([(@config[:max_processes] * @config[:max_threads] * 2), 100].max)
      @in_flight_count = Concurrent::AtomicFixnum.new(0)
      @produced_count = Concurrent::AtomicFixnum.new(0)

      # Start producer and accumulator threads
      producer_thread = start_producer
      accumulator_thread = start_accumulator

      # Wait for completion
      producer_thread.join
      accumulator_thread.join
    end

    def find_stage(name)
      @stages[name]
    end

    def is_terminal_stage?(stage_name)
      @dag.terminal?(stage_name)
    end

    def get_targets(stage_name)
      targets = @dag.downstream(stage_name)

      # If no targets and we have output queues, this is an output stage
      if targets.empty? && !@output_queues.empty? && !is_terminal_stage?(stage_name)
        return [:output]
      end

      targets
    end

    # Helper methods to find stages by characteristics
    def find_producer
      @stages.values.find { |stage| stage.producer? }
    end

    def find_all_producers
      @stages.values.select do |stage|
        if stage.is_a?(PipelineStage)
          # PipelineStage is a producer if it has no upstream
          @dag.upstream(stage.name).empty?
        else
          stage.producer?
        end
      end
    end

    def find_accumulator
      @stages.values.find { |stage| stage.accumulator? }
    end

    private

    def start_producer
      queue = @queue
      produced_count = @produced_count
      in_flight_count = @in_flight_count
      producer_stages = find_all_producers

      # Handle both internal producers and input from upstream pipeline
      has_internal_producers = producer_stages.any?
      has_input_queues = @input_queues.any?

      Thread.new do
        producer_threads = []

        if has_internal_producers
          # Separate AtomicStage producers and PipelineStage producers
          atomic_producers = producer_stages.select { |p| p.is_a?(AtomicStage) && p.block }
          pipeline_producers = producer_stages.select { |p| p.is_a?(PipelineStage) }

          log_info "[Pipeline:#{@name}][Producers] Starting #{atomic_producers.size} atomic producer(s) and #{pipeline_producers.size} pipeline producer(s)"

          # Start atomic producers
          atomic_producers.each do |producer_stage|
            producer_threads << Thread.new do
              producer_name = producer_stage.name
              stage_stats = @stats.for_stage(producer_name, is_terminal: false)
              stage_stats.start!

              log_info "[Pipeline:#{@name}][Producer:#{producer_name}] Starting"

              begin
                # Execute before hooks for this producer
                execute_stage_hooks(:before, producer_name)

                # Create emit method for this producer (thread-local context)
                producer_context = @context.dup
                emit_proc = proc do |item|
                  in_flight_count.increment
                  queue << [item, producer_name]
                  produced_count.increment
                  stage_stats.increment_produced
                end

                # Bind emit to this producer's context
                producer_context.define_singleton_method(:emit, &emit_proc)

                # Run producer block
                producer_context.instance_eval(&producer_stage.block)

                stage_stats.finish!
                log_info "[Pipeline:#{@name}][Producer:#{producer_name}] Done. Produced #{stage_stats.items_produced} items"

                # Execute after hooks for this producer
                execute_stage_hooks(:after, producer_name)
              rescue => e
                stage_stats.finish!
                log_info "[Pipeline:#{@name}][Producer:#{producer_name}] Error: #{e.message}"
                # Don't propagate error - other producers should continue
              end
            end
          end

          # Start pipeline producers
          pipeline_producers.each do |pipeline_stage|
            producer_threads << Thread.new do
              producer_name = pipeline_stage.name
              stage_stats = @stats.for_stage(producer_name, is_terminal: false)
              stage_stats.start!

              log_info "[Pipeline:#{@name}][PipelineProducer:#{producer_name}] Starting"

              begin
                # Run the nested pipeline and capture its output
                emitted_items = []
                emit_mutex = Mutex.new

                producer_context = @context.dup
                producer_context.define_singleton_method(:emit) do |item|
                  emit_mutex.synchronize { emitted_items << item }
                end

                # Run the pipeline
                pipeline_stage.pipeline.instance_variable_set(:@job_id, @job_id)
                pipeline_stage.pipeline.run(producer_context)

                # Emit all items into the queue
                emitted_items.each do |item|
                  in_flight_count.increment
                  queue << [item, producer_name]
                  produced_count.increment
                  stage_stats.increment_produced
                end

                stage_stats.finish!
                log_info "[Pipeline:#{@name}][PipelineProducer:#{producer_name}] Done. Produced #{stage_stats.items_produced} items"
              rescue => e
                stage_stats.finish!
                log_error "[Pipeline:#{@name}][PipelineProducer:#{producer_name}] Error: #{e.message}"
                log_error e.backtrace.join("\n")
              end
            end
          end
        end

        if has_input_queues
          # Consume from input queues (upstream pipelines)
          @input_queues.each_with_index do |input_queue, idx|
            producer_threads << Thread.new do
              log_info "[Pipeline:#{@name}][Input-#{idx}] Waiting for upstream items"

              loop do
                item = input_queue.pop
                break if item == :END_OF_QUEUE

                in_flight_count.increment
                queue << [item, :_input]
                produced_count.increment
              end

              log_info "[Pipeline:#{@name}][Input-#{idx}] Upstream finished"
            end
          end
        end

        # Wait for all producers to finish
        producer_threads.each(&:join)

        # Wait for all items to be processed
        sleep 0.01 while in_flight_count.value > 0

        # Signal end
        queue << :END_OF_QUEUE
      end
    end

    def start_accumulator
      Thread.new do
        log_info "[Pipeline:#{@name}][Accumulator] Starting"

        output_items = []  # Track items to send to downstream pipelines

        loop do
          item_data = @queue.pop
          break if item_data == :END_OF_QUEUE

          item, source_stage = item_data
          targets = get_targets(source_stage)

          @in_flight_count.decrement

          targets.each do |target_name|
            target_stage = find_stage(target_name)
            next unless target_stage

            if @dag.terminal?(target_name)
              # Terminal stage (consumer) - execute immediately
              execute_consumers({ target_name => [{ item: item, stage: target_stage }] }, output_items)
            else
              # Processor, Accumulator, or Pipeline - execute and route outputs
              emitted_items = execute_stage(target_stage, item)

              emitted_items.each do |emitted_item|
                @in_flight_count.increment
                @queue << [emitted_item, target_name]
              end
            end
          end
        end

        # Flush all accumulators to emit any remaining items
        @stages.each_value do |stage|
          next unless stage.accumulator?

          flushed_items = stage.flush(@context)
          flushed_items.each do |batch|
            # Send batch to downstream stages
            downstream_targets = @dag.downstream(stage.name)
            downstream_targets.each do |downstream_name|
              downstream_stage = find_stage(downstream_name)

              if @dag.terminal?(downstream_name)
                # Execute consumer immediately
                execute_consumers({ downstream_name => [{ item: batch, stage: downstream_stage }] }, output_items)
              else
                # Process through downstream stage
                next_items = execute_stage(downstream_stage, batch)
                next_items.each do |next_item|
                  # Find final consumers
                  final_targets = @dag.downstream(downstream_name)
                  final_targets.each do |final_name|
                    final_stage = find_stage(final_name)
                    if @dag.terminal?(final_name)
                      execute_consumers({ final_name => [{ item: next_item, stage: final_stage }] }, output_items)
                    end
                  end
                end
              end
            end
          end
        end

        # Send items to output queues if this pipeline has downstream pipelines
        send_to_output_queues(output_items)

        log_info "[Pipeline:#{@name}][Accumulator] Done"
      end
    end

    # Execute consumers using the new execution context system
    def execute_consumers(consumer_batches, output_items)
      require_relative 'execution/stage_executor'
      executor = Execution::StageExecutor.new(self, @config)

      begin
        executor.execute_batch(consumer_batches, output_items, @context, @stats, @stage_hooks)
      ensure
        executor.shutdown
      end
    end

    # Send completed items to downstream pipelines
    def send_to_output_queues(output_items)
      return if @output_queues.empty?

      log_info "[Pipeline:#{@name}] Sending #{output_items.size} items to downstream pipelines"

      @output_queues.each do |pipeline_name, queue|
        output_items.each do |item|
          queue << item
        end
        queue << :END_OF_QUEUE
        log_info "[Pipeline:#{@name}] Sent #{output_items.size} items + END_OF_QUEUE to #{pipeline_name}"
      end
    end

    def execute_stage(stage, item)
      # Terminal stages are final consumers
      is_terminal = @dag.terminal?(stage.name)
      stage_stats = @stats.for_stage(stage.name, is_terminal: is_terminal)
      stage_stats.start! unless stage_stats.start_time
      start_time = Time.now

      # Execute before hooks for this stage
      execute_stage_hooks(:before, stage.name)

      # Track consumption of input item
      stage_stats.increment_consumed

      result = if stage.respond_to?(:execute_with_emit)
        stage.execute_with_emit(@context, item)
      else
        stage.execute(@context, item)
        []
      end

      # Track production of output items
      stage_stats.increment_produced(result.size)

      # Record latency
      duration = Time.now - start_time
      stage_stats.record_latency(duration)

      # Execute after hooks for this stage
      execute_stage_hooks(:after, stage.name)

      result
    end

    def build_dag_routing!
      # If this pipeline receives input from upstream, add :_input node and route it
      if @input_queues.any?
        handle_input_queue_routing!
      end

      # Handle multiple producers specially - they should all connect to first non-producer
      handle_multiple_producers_routing!

      # Fill any remaining sequential gaps (handles fan-out, siblings, cycles)
      fill_sequential_gaps_by_definition_order!

      @dag.validate!
      validate_stages_exist!

      log_info "#{log_prefix} DAG: #{@dag.topological_sort.join(' -> ')}"
    end

    def validate_stages_exist!
      @dag.nodes.each do |node_name|
        next if node_name == :_input  # Special internal node for input queue

        unless find_stage(node_name)
          raise Minigun::Error, "[Pipeline:#{@name}] Routing references non-existent stage '#{node_name}'"
        end
      end
    end

    def handle_input_queue_routing!
      # Add :_input as an internal DAG node for items from upstream pipeline
      @dag.add_node(:_input) unless @dag.nodes.include?(:_input)

      # Route :_input to the first non-producer stage (same logic as multiple producers)
      first_non_producer = @stage_order.find { |s| !find_stage(s)&.producer? }

      if first_non_producer
        @dag.add_edge(:_input, first_non_producer)
      end
    end

    def handle_multiple_producers_routing!
      producers = @stage_order.select { |s| find_stage(s)&.producer? }

      # Each producer without explicit routing should connect to its next stage in definition order
      producers.each do |producer_name|
        # Skip if this producer already has explicit downstream edges
        next unless @dag.downstream(producer_name).empty?

        # Find the next non-producer stage after this producer
        producer_index = @stage_order.index(producer_name)
        next_stage = @stage_order[(producer_index + 1)..-1].find { |s| !find_stage(s)&.producer? }

        if next_stage
          @dag.add_edge(producer_name, next_stage)
        end
      end
    end

    def fill_sequential_gaps_by_definition_order!
      # Then fill remaining sequential gaps
      @stage_order.each_with_index do |stage_name, index|
        # Skip if already has downstream edges
        next if @dag.downstream(stage_name).any?
        # Skip if this is the last stage
        next if index >= @stage_order.size - 1

        next_stage = @stage_order[index + 1]

        # Skip if BOTH current and next are PipelineStages (isolated pipelines)
        current_stage = find_stage(stage_name)
        next_stage_obj = find_stage(next_stage)
        if current_stage.is_a?(PipelineStage) && next_stage_obj.is_a?(PipelineStage)
          next
        end

        # Skip if this is a fan-out pattern (next_stage is a sibling)
        next if @dag.fan_out_siblings?(stage_name, next_stage)

        # Skip if any sibling already routes to next_stage
        siblings = @dag.siblings(stage_name)
        next if siblings.any? { |sib| @dag.downstream(sib).include?(next_stage) }

        # Don't add edge if it would create a cycle
        next if @dag.would_create_cycle?(stage_name, next_stage)

        @dag.add_edge(stage_name, next_stage)
      end
    end

    def log_prefix
      if @job_id
        "[Job:#{@job_id}][Pipeline:#{@name}]"
      else
        "[Pipeline:#{@name}]"
      end
    end

    def log_info(msg)
      Minigun.logger.info(msg)
    end

    def log_error(msg)
      Minigun.logger.error(msg)
    end
  end
end
