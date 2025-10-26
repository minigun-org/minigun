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
      # Insert router stages for fan-out
      insert_router_stages_for_fan_out

      # Create one input queue per stage (except producers)
      @stage_input_queues = build_stage_input_queues
      @produced_count = Concurrent::AtomicFixnum.new(0)
      @stage_threads = []

      # Track runtime edges (who sends to whom) for dynamic routing termination
      # Key: source stage, Value: Set of target stages
      @runtime_edges = Concurrent::Hash.new { |h, k| h[k] = Concurrent::Set.new }

      # Start producer threads
      producer_threads = start_producers

      # Start stage worker threads (one per non-producer stage, including routers)
      @stages.each do |stage_name, stage|
        next if stage.producer?
        # Skip PipelineStage producers (those with no upstream)
        next if stage.is_a?(PipelineStage) && @dag.upstream(stage_name).empty?
        @stage_threads << start_stage_worker(stage_name, stage)
      end

      # Wait for all stage workers to finish
      @stage_threads.each(&:join)
    end

    # Build one input queue per stage (except producers)
    def build_stage_input_queues
      queues = {}

      @stages.each do |stage_name, stage|
        # Skip producers - they don't have input queues
        next if stage.producer?

        queues[stage_name] = Queue.new  # Unbounded to prevent deadlock
      end

      queues
    end

    # Insert RouterStage instances for fan-out patterns
    def insert_router_stages_for_fan_out
      stages_to_add = []
      dag_updates = []

      @stages.each do |stage_name, stage|
        downstream = @dag.downstream(stage_name)

        # Fan-out: stage has multiple downstream consumers
        if downstream.size > 1
          # Get explicit routing strategy from stage options, or default to :broadcast
          routing_strategy = stage.options[:routing] || :broadcast

          # Create a RouterStage
          router_name = :"#{stage_name}_router"
          router_stage = RouterStage.new(
            name: router_name,
            targets: downstream.dup,
            routing_strategy: routing_strategy
          )
          stages_to_add << [router_name, router_stage]

          # Update DAG: stage -> router -> [downstream targets]
          dag_updates << {
            remove_edges: downstream.map { |target| [stage_name, target] },
            add_edge: [stage_name, router_name],
            add_router_edges: downstream.map { |target| [router_name, target] }
          }

          log_info "[Pipeline:#{@name}] Inserting RouterStage '#{router_name}' (#{routing_strategy}) for fan-out: #{stage_name} -> #{downstream.join(', ')}"
        end
      end

      # Apply DAG updates
      dag_updates.each do |update|
        update[:remove_edges].each { |(from, to)| @dag.remove_edge(from, to) }
        @dag.add_edge(update[:add_edge][0], update[:add_edge][1])
        update[:add_router_edges].each { |(from, to)| @dag.add_edge(from, to) }
      end

      # Add router stages to @stages
      stages_to_add.each do |name, stage|
        @stages[name] = stage
      end
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


    private

    # Start all producer threads
    def start_producers
      producer_stages = find_all_producers
      return [] if producer_stages.empty?

      producer_stages.map do |producer_stage|
        start_producer_thread(producer_stage)
      end
    end

    # Start a worker thread for a non-producer stage
    def start_stage_worker(stage_name, stage)
      Thread.new do
        log_info "[Pipeline:#{@name}][Worker:#{stage_name}] Starting"

        # Get input queue for this stage
        input_queue = @stage_input_queues[stage_name]

        unless input_queue
          log_info "[Pipeline:#{@name}][Worker:#{stage_name}] No input queue, exiting"
          next
        end

        # Track sources: we know DAG upstream at start, discover dynamic sources at runtime
        # We exit when all known sources have sent END
        dag_upstream = @dag.upstream(stage_name)
        sources_expected = Set.new(dag_upstream)  # Start with DAG upstream
        sources_done = Set.new
        runtime_edges = @runtime_edges
        stage_input_queues = @stage_input_queues
        
        # If no DAG upstream and stage is a regular consumer/processor (not a producer or PipelineStage), 
        # something is wrong - exit immediately to prevent hanging
        if sources_expected.empty? && !stage.producer? && !stage.is_a?(PipelineStage)
          log_info "[Pipeline:#{@name}][Worker:#{stage_name}] No upstream sources, exiting"
          next
        end

        # For routers, route according to strategy (broadcast or round-robin)
        if stage.respond_to?(:router?) && stage.router?
          target_queues = stage.targets.map { |target| stage_input_queues[target] }

          if stage.round_robin?
            # Round-robin load balancing
            round_robin_index = 0

            loop do
              msg = input_queue.pop

              # Handle END signal
              if msg.is_a?(Message) && msg.end_of_stream?
                sources_expected << msg.source  # Discover dynamic source
                sources_done << msg.source
                break if sources_done == sources_expected
                next
              end

              # Round-robin to downstream stages
              # Don't track in runtime_edges - router targets are known statically
              target = stage.targets[round_robin_index]
              target_queues[round_robin_index] << msg
              round_robin_index = (round_robin_index + 1) % target_queues.size
            end
          else
            # Broadcast (default)
            loop do
              msg = input_queue.pop

              # Handle END signal
              if msg.is_a?(Message) && msg.end_of_stream?
                sources_expected << msg.source  # Discover dynamic source
                sources_done << msg.source
                break if sources_done == sources_expected
                next
              end

              # Broadcast to all downstream stages (fan-out semantics)
              # Don't track in runtime_edges - router targets are known statically
              stage.targets.each do |target|
                stage_input_queues[target] << msg
              end
            end
          end

          # Broadcast END to ALL router targets (even for round-robin)
          # All targets need to know when upstream is complete
          stage.targets.each do |target|
            stage_input_queues[target] << Message.end_signal(source: stage_name)
          end
        else
          # Regular stage processing
          loop do
            msg = input_queue.pop

            # Handle END signal
            if msg.is_a?(Message) && msg.end_of_stream?
              sources_expected << msg.source  # Discover dynamic source
              sources_done << msg.source
              break if sources_done == sources_expected
              next
            end

            # Execute the stage
            item = msg  # msg is unwrapped data
            results = execute_stage(stage, item)

            # Route results to downstream stages and track edges
            results.each do |result|
              if result.is_a?(Hash) && result.key?(:item) && result.key?(:target)
                # Targeted emit via emit_to_stage - route DIRECTLY to target's input queue
                target_stage = result[:target]
                output_queue = stage_input_queues[target_stage]
                if output_queue
                  runtime_edges[stage_name].add(target_stage)
                  output_queue << result[:item]
                end
              else
                # Regular emit - uses DAG routing to all downstream
                # Don't track in runtime_edges - DAG already knows these connections
                downstream = @dag.downstream(stage_name)
                downstream.each do |downstream_stage|
                  output_queue = stage_input_queues[downstream_stage]
                  output_queue << result if output_queue
                end
              end
            end
          end

          # Send END to ALL connections: DAG downstream + dynamic emit_to_stage targets
          dag_downstream = @dag.downstream(stage_name)
          dynamic_targets = runtime_edges[stage_name].to_a
          all_targets = (dag_downstream + dynamic_targets).uniq
          
          all_targets.each do |target|
            stage_input_queues[target] << Message.end_signal(source: stage_name)
          end
        end

        log_info "[Pipeline:#{@name}][Worker:#{stage_name}] Done"
      end
    end

    def start_producer_old
      produced_count = @produced_count
      producer_stages = find_all_producers

      # Handle both internal producers and input from upstream pipeline
      has_internal_producers = producer_stages.any?
      has_input_queues = @input_queues.any?

      Thread.new do
        producer_threads = []

        if has_internal_producers
          log_info "[Pipeline:#{@name}][Producers] Starting #{producer_stages.size} producer(s)"

          # Start all producers (atomic and pipeline)
          producer_stages.each do |producer_stage|
            producer_threads << start_producer_thread(producer_stage, queue, in_flight_count, produced_count)
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

    # Start a single producer thread (handles both atomic and pipeline producers)
    def start_producer_thread(producer_stage)
      # Capture instance variables for closure
      produced_count = @produced_count
      stage_input_queues = @stage_input_queues
      runtime_edges = @runtime_edges

      Thread.new do
        producer_name = producer_stage.name
        stage_stats = @stats.for_stage(producer_name, is_terminal: false)
        stage_stats.start!

        is_pipeline = producer_stage.is_a?(PipelineStage)
        log_info "[Pipeline:#{@name}][Producer:#{producer_name}] Starting #{is_pipeline ? '(nested pipeline)' : ''}"

        begin
          # Execute before hooks for this producer
          execute_stage_hooks(:before, producer_name) unless is_pipeline

          # Create producer context with emit methods
          producer_context = @context.dup

          # Get downstream stage input queues
          downstream = @dag.downstream(producer_name)
          downstream_queues = downstream.map { |to| stage_input_queues[to] }.compact

          if is_pipeline
            # Pipeline producers: collect items, then emit all at once
            emitted_items = []
            emit_mutex = Mutex.new

            producer_context.define_singleton_method(:emit) do |item|
              emit_mutex.synchronize { emitted_items << item }
            end

            # Run the nested pipeline
            producer_stage.pipeline.instance_variable_set(:@job_id, @job_id)
            producer_stage.pipeline.run(producer_context)

            # Emit all collected items to downstream queues
            # Don't track in runtime_edges - DAG already knows these connections
            emitted_items.each do |item|
              downstream.each do |target|
                stage_input_queues[target] << item
              end
              produced_count.increment
              stage_stats.increment_produced
            end
          else
            # Atomic producers: emit directly to downstream queues as they produce
            # Don't track regular emits - only emit_to_stage
            producer_context.define_singleton_method(:emit) do |item|
              downstream.each do |target|
                stage_input_queues[target] << item
              end
              produced_count.increment
              stage_stats.increment_produced
            end

            producer_context.define_singleton_method(:emit_to_stage) do |target_stage, item|
              # emit_to_stage writes DIRECTLY to target's input queue and tracks edge
              queue = stage_input_queues[target_stage]
              if queue
                runtime_edges[producer_name].add(target_stage)
                queue << item
                produced_count.increment
                stage_stats.increment_produced
              end
            end

            # Run producer block
            producer_context.instance_eval(&producer_stage.block)
          end

          stage_stats.finish!
          log_info "[Pipeline:#{@name}][Producer:#{producer_name}] Done. Produced #{stage_stats.items_produced} items"

          # Send END signal to ALL connections: DAG downstream + dynamic emit_to_stage targets
          dynamic_targets = runtime_edges[producer_name].to_a
          all_targets = (downstream + dynamic_targets).uniq

          all_targets.each do |target|
            stage_input_queues[target] << Message.end_signal(source: producer_name)
          end

          # Execute after hooks for this producer
          execute_stage_hooks(:after, producer_name) unless is_pipeline
        rescue => e
          stage_stats.finish!
          log_error "[Pipeline:#{@name}][Producer:#{producer_name}] Error: #{e.message}"
          log_error e.backtrace.join("\n") if is_pipeline
          # Don't propagate error - other producers should continue
        end
      end
    end

    # Main event loop: processes items from queue and routes them to target stages
    def start_dispatcher
      Thread.new do
        log_info "[Pipeline:#{@name}][Dispatcher] Starting"

        output_items = []  # Track items to send to downstream pipelines

        loop do
          begin
            item_data = @queue.pop
            break if item_data == :END_OF_QUEUE

            item, source_stage, explicit_target = item_data

            # Use explicit target if provided, otherwise use DAG routing
            targets = if explicit_target
                        [explicit_target]
                      else
                        get_targets(source_stage)
                      end

            @in_flight_count.decrement

            targets.each do |target_name|
            target_stage = find_stage(target_name)

            # Validate that explicit target exists
            if explicit_target && !target_stage
              log_error "[Pipeline:#{@name}] emit_to_stage: Unknown target stage '#{target_name}'"
              next
            end

            next unless target_stage

            if @dag.terminal?(target_name)
              # Terminal stage (consumer) - execute through unified path
              execute_stage(target_stage, item)
            else
              # Processor, Accumulator, or Pipeline - execute and route outputs
              emitted_results = execute_stage(target_stage, item)

              # Handle both plain items and targeted items (emit_to_stage)
              emitted_results.each do |result|
                if result.is_a?(Hash) && result.key?(:item) && result.key?(:target)
                  # Targeted emit via emit_to_stage - has explicit target
                  @in_flight_count.increment
                  @queue << [result[:item], target_name, result[:target]]
                else
                  # Regular emit - uses DAG routing
                  @in_flight_count.increment
                  @queue << [result, target_name, nil]
                end
              end
            end
          end
          rescue => e
            log_error "[Pipeline:#{@name}][Dispatcher] Error: #{e.message}"
            log_error e.backtrace.join("\n")
            raise
          end
        end

        # Flush any stages with remaining buffered items
        @stages.each_value do |stage|
          next unless stage.respond_to?(:flush)

          flushed_items = stage.flush(@context)
          flushed_items.each do |batch|
            # Send batch to downstream stages
            downstream_targets = @dag.downstream(stage.name)
            downstream_targets.each do |downstream_name|
              downstream_stage = find_stage(downstream_name)

              if @dag.terminal?(downstream_name)
                # Execute consumer through unified path
                execute_stage(downstream_stage, batch)
              else
                # Process through downstream stage
                next_items = execute_stage(downstream_stage, batch)
                next_items.each do |next_item|
                  # Find final consumers
                  final_targets = @dag.downstream(downstream_name)
                  final_targets.each do |final_name|
                    final_stage = find_stage(final_name)
                    if @dag.terminal?(final_name)
                      execute_stage(final_stage, next_item)
                    end
                  end
                end
              end
            end
          end
        end

        # Send items to output queues if this pipeline has downstream pipelines
        send_to_output_queues(output_items)

        log_info "[Pipeline:#{@name}][Dispatcher] Done"
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
      executor = Execution::StageExecutor.new(self, @config)
      item_data = { item: item, stage: stage }
      executor.execute_with_context(stage.execution_context, [item_data])
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
