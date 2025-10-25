# frozen_string_literal: true

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
        accumulator_max_single: config[:accumulator_max_single] || 2000,
        accumulator_max_all: config[:accumulator_max_all] || 4000,
        accumulator_check_interval: config[:accumulator_check_interval] || 100,
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

      @produced_count = Concurrent::AtomicFixnum.new(0)
      @in_flight_count = Concurrent::AtomicFixnum.new(0)
      @accumulated_count = 0
      @consumer_pids = []

      # Statistics tracking
      @stats = nil  # Will be initialized in run()

      # For multi-pipeline communication
      @input_queue = nil
      @output_queues = {}  # { pipeline_name => queue }
    end

    # Set an input queue for receiving items from upstream pipelines
    def input_queue=(queue)
      @input_queue = queue
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
      # We'll add to stage_order after we create the stage so we know what it is

      # Extract routing information
      to_targets = options.delete(:to)
      if to_targets
        Array(to_targets).each { |target| @dag.add_edge(name, target) }
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
    # Example: reroute_stage :producer, to: :new_processor (instead of :consumer)
    # This removes producer's old edges and adds new ones
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

      # Start internal queue (for stage-to-stage communication)
      @queue = SizedQueue.new(@config[:max_processes] * @config[:max_threads] * 2)

      # Start producer, isolated pipelines, and accumulator threads
      producer_thread = start_producer
      isolated_pipeline_threads = start_isolated_pipelines
      accumulator_thread = start_accumulator

      # Wait for completion
      producer_thread.join
      isolated_pipeline_threads.each(&:join)
      accumulator_thread.join
      wait_all_consumers

      @job_end = Time.now
      @stats.finish!

      log_info "#{log_prefix} Finished in #{(@job_end - @job_start).round(2)}s"
      log_info "#{log_prefix} Produced: #{@produced_count.value}, Accumulated: #{@accumulated_count}"

      # Run after_run hooks
      @hooks[:after_run].each { |h| context.instance_eval(&h) }

      # Return produced count (or accumulated count if using accumulator)
      @accumulated_count > 0 ? @accumulated_count : @produced_count.value
    end

    # Run this pipeline in a thread (for multi-pipeline execution)
    def run_in_thread(context)
      Thread.new do
        run(context)
      rescue => e
        log_error "[Pipeline:#{@name}] Error: #{e.message}"
        log_error e.backtrace.join("\n")
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
      # (Only non-terminal stages should output to queues - terminal stages consume)
      if targets.empty? && !@output_queues.empty? && !is_terminal_stage?(stage_name)
        # This item should be sent to output queues
        return [:output]
      end

      targets
    end

    # Helper methods to find stages by characteristics
    def find_producer
      @stages.values.find { |stage| stage.producer? }
    end

    def find_all_producers
      @stages.values.select { |stage| stage.producer? }
    end

    def find_accumulator
      @stages.values.find { |stage| stage.accumulator? }
    end

    def find_consumers_with_spawn_strategies
      spawn_strategies = [:spawn_thread, :spawn_fork, :spawn_ractor]
      @stages.values.select { |stage| spawn_strategies.include?(stage.strategy) }
    end

    private

    def start_producer
      queue = @queue
      produced_count = @produced_count
      in_flight_count = @in_flight_count
      producer_stages = find_all_producers

      # Handle both internal producers and input from upstream pipeline
      has_internal_producers = producer_stages.any? { |p| p.block }
      has_input_queue = @input_queue

      Thread.new do
        producer_threads = []

        if has_internal_producers
          # Start each producer in its own thread
          producers_with_blocks = producer_stages.select { |p| p.block }
          log_info "[Pipeline:#{@name}][Producers] Starting #{producers_with_blocks.size} producer(s)"

          producers_with_blocks.each do |producer_stage|
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
        end

        if has_input_queue
          # Consume from input queue (upstream pipeline)
          producer_threads << Thread.new do
            log_info "[Pipeline:#{@name}][Input] Waiting for upstream items"

            loop do
              item = @input_queue.pop
              break if item == :END_OF_QUEUE

              in_flight_count.increment
              queue << [item, :_input]
              produced_count.increment
            end

            log_info "[Pipeline:#{@name}][Input] Upstream finished"
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

    def start_isolated_pipelines
      # Find PipelineStages that have no upstream connections (isolated pipelines)
      isolated_pipelines = @stages.values.select do |stage|
        stage.is_a?(PipelineStage) && @dag.upstream(stage.name).empty?
      end

      return [] if isolated_pipelines.empty?

      log_info "[Pipeline:#{@name}][Isolated] Starting #{isolated_pipelines.size} isolated pipeline(s)"

      # Start each isolated pipeline in its own thread
      isolated_pipelines.map do |pipeline_stage|
        Thread.new do
          log_info "[Pipeline:#{@name}][Isolated:#{pipeline_stage.name}] Starting"

          begin
            # Run the nested pipeline with the current context
            pipeline_stage.pipeline.run(@context)

            log_info "[Pipeline:#{@name}][Isolated:#{pipeline_stage.name}] Completed"
          rescue => e
            log_info "[Pipeline:#{@name}][Isolated:#{pipeline_stage.name}] Error: #{e.message}"
          end
        end
      end
    end

    def start_accumulator
      Thread.new do
        log_info "[Pipeline:#{@name}][Accumulator] Starting"

        consumer_queues = Hash.new { |h, k| h[k] = [] }
        accumulator_buffers = Hash.new { |h, k| h[k] = [] }  # Buffers for accumulator stages
        output_items = []  # Track items to send to downstream pipelines
        check_counter = 0

        loop do
          item_data = @queue.pop
          break if item_data == :END_OF_QUEUE

          item, source_stage = item_data
          targets = get_targets(source_stage)

          @in_flight_count.decrement

          targets.each do |target_name|
            target_stage = find_stage(target_name)
            next unless target_stage

            if target_stage.accumulator?
              # Accumulator stage - batch items
              accumulator_buffers[target_name] << item

              # Check if we've reached the batch size
              if accumulator_buffers[target_name].size >= target_stage.max_size
                batch = accumulator_buffers[target_name].dup
                accumulator_buffers[target_name].clear

                # Execute accumulator logic if any (e.g., grouping)
                processed_batch = target_stage.execute(@context, batch)

                # Send batch directly to downstream consumers (don't re-queue)
                downstream_targets = @dag.downstream(target_name)
                downstream_targets.each do |downstream_name|
                  downstream_stage = find_stage(downstream_name)

                  if @dag.terminal?(downstream_name)
                    # Add batch to consumer queue
                    consumer_queues[downstream_name] << { item: processed_batch, stage: downstream_stage, output_items: output_items }
                  else
                    # Non-terminal - re-queue for further processing
                    @in_flight_count.increment
                    @queue << [processed_batch, target_name]
                  end
                end

                @accumulated_count += batch.size
              end
            elsif @dag.terminal?(target_name)
              # Terminal stage (consumer) - accumulate for batch processing
              consumer_queues[target_name] << { item: item, stage: target_stage, output_items: output_items }
              check_counter += 1

              if check_counter % @config[:accumulator_check_interval] == 0
                check_and_fork(consumer_queues, output_items)
              end
            else
              # Processor or Pipeline - execute and route outputs
              emitted_items = execute_stage(target_stage, item)

              emitted_items.each do |emitted_item|
                @in_flight_count.increment
                @queue << [emitted_item, target_name]
              end
            end
          end
        end

        # Process remaining batches in accumulators
        accumulator_buffers.each do |accum_name, items|
          next if items.empty?

          accum_stage = find_stage(accum_name)
          processed_batch = accum_stage.execute(@context, items)

          # Send final batch to downstream
          downstream_targets = @dag.downstream(accum_name)
          downstream_targets.each do |downstream_name|
            downstream_stage = find_stage(downstream_name)

            if @dag.terminal?(downstream_name)
              # Add to consumer queue
              consumer_queues[downstream_name] << { item: processed_batch, stage: downstream_stage, output_items: output_items }
            end
          end

          @accumulated_count += items.size
        end

        # Process remaining consumer items
        fork_consumer(consumer_queues, output_items) unless consumer_queues.empty?

        # Send items to output queues if this pipeline has downstream pipelines
        send_to_output_queues(output_items)

        log_info "[Pipeline:#{@name}][Accumulator] Done. Accumulated #{@accumulated_count} items"
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

    def check_and_fork(accumulator_map, output_items)
      accumulator_map.each do |key, items|
        if items.size >= @config[:accumulator_max_single]
          fork_consumer({ key => accumulator_map.delete(key) }, output_items)
        end
      end

      total = accumulator_map.values.sum(&:size)
      if total >= @config[:accumulator_max_all]
        fork_consumer(accumulator_map.dup, output_items)
        accumulator_map.clear
      end
    end

    def fork_consumer(batch_map, output_items)
      total_items = batch_map.values.sum(&:size)

      # Group consumers by strategy
      strategy_groups = Hash.new { |h, k| h[k] = {} }

      batch_map.each do |consumer_name, items|
        # Get strategy from first item's stage (all items for a consumer have same strategy)
        strategy = items.first[:stage].strategy
        strategy_groups[strategy][consumer_name] = items
      end

      # Execute each strategy group
      strategy_groups.each do |strategy, consumer_batch|
        case strategy
        when :spawn_fork
          if Process.respond_to?(:fork)
            fork_consumer_process(consumer_batch, output_items, total_items)
          else
            consume_in_threads(consumer_batch, output_items, total_items)
          end
        when :spawn_thread
          consume_in_threads(consumer_batch, output_items, total_items)
        when :spawn_ractor
          consume_in_ractors(consumer_batch, output_items, total_items)
        when :fork_ipc
          if Process.respond_to?(:fork)
            fork_consumer_ipc(consumer_batch, output_items, total_items)
          else
            consume_in_threads(consumer_batch, output_items, total_items)
          end
        when :ractor
          consume_in_ractors(consumer_batch, output_items, total_items)
        when :threaded, nil
          consume_in_threads(consumer_batch, output_items, total_items)
        else
          raise Minigun::Error, "Unknown consumer strategy: #{strategy}"
        end
      end
    end

    def fork_consumer_process(batch_map, output_items, total_items)
      wait_for_consumer_slot

      log_info "[Pipeline:#{@name}][Fork] Forking to process #{total_items} items"

      # Execute pipeline-level before_fork hooks
      @hooks[:before_fork].each { |h| @context.instance_eval(&h) }

      # Execute stage-specific before_fork hooks for all consumer stages in this batch
      consumer_stages = batch_map.values.flat_map { |items| items.map { |i| i[:stage] } }.uniq
      consumer_stages.each do |stage|
        execute_stage_hooks(:before_fork, stage.name)
      end

      GC.start if @consumer_pids.empty? || @consumer_pids.size % 4 == 0

      pid = fork do
        @pid = Process.pid

        # Set process title for easier identification in ps/top
        if Process.respond_to?(:setproctitle)
          Process.setproctitle("minigun-#{@name}-consumer-#{@pid}")
        end

        # Execute pipeline-level after_fork hooks
        @hooks[:after_fork].each { |h| @context.instance_eval(&h) }

        # Execute stage-specific after_fork hooks for all consumer stages in this batch
        consumer_stages.each do |stage|
          execute_stage_hooks(:after_fork, stage.name)
        end

        log_info "[Pipeline:#{@name}][Consumer:#{@pid}] Started"
        consume_batch(batch_map, output_items)
        log_info "[Pipeline:#{@name}][Consumer:#{@pid}] Done"

        exit! 0
      end

      @consumer_pids << pid
    end

    def fork_consumer_ipc(batch_map, output_items, total_items)
      # IPC implementation - similar to fork but with serialized communication
      # For now, delegate to regular fork
      fork_consumer_process(batch_map, output_items, total_items)
    end

    def consume_in_threads(batch_map, output_items, total_items)
      log_info "[Pipeline:#{@name}][Consumer] Processing #{total_items} items (threaded)"
      consume_batch(batch_map, output_items)
    end

    def consume_in_ractors(batch_map, output_items, total_items)
      log_info "[Pipeline:#{@name}][Consumer] Processing #{total_items} items (ractors)"
      # Ractor implementation - for now, fall back to threads
      # TODO: Implement true ractor-based execution
      consume_batch(batch_map, output_items)
    end

    def consume_batch(batch_map, output_items)
      thread_pool = Concurrent::FixedThreadPool.new(@config[:max_threads])
      processed = Concurrent::AtomicFixnum.new(0)
      mutex = Mutex.new

      # Check if we have downstream pipelines
      has_downstream = !@output_queues.empty?

      batch_map.each do |_consumer_name, item_data_array|
        item_data_array.each do |item_data|
          Concurrent::Future.execute(executor: thread_pool) do
            item = item_data[:item]
            stage = item_data[:stage]
            # Terminal consumers don't produce items
            stage_stats = @stats.for_stage(stage.name, is_terminal: true)
            stage_stats.start! unless stage_stats.start_time
            start_time = Time.now

            if has_downstream
              # Create emit method for consumer to send to downstream pipelines
              emit_proc = proc do |emitted_item|
                mutex.synchronize { output_items << emitted_item }
              end
              @context.define_singleton_method(:emit, &emit_proc)
            end

            stage.execute(@context, item)

            # Track consumption
            stage_stats.increment_consumed

            # Record latency
            duration = Time.now - start_time
            stage_stats.record_latency(duration)

            processed.increment
          end
        end
      end

      thread_pool.shutdown
      thread_pool.wait_for_termination(30)

      log_info "[Pipeline:#{@name}][Consumer] Processed #{processed.value} items"
    end

    def wait_for_consumer_slot
      return if @consumer_pids.size < @config[:max_processes]

      pid = Process.wait
      @consumer_pids.delete(pid)
    rescue Errno::ECHILD
      # No children
    end

    def wait_all_consumers
      @consumer_pids.each do |pid|
        Process.wait(pid)
      rescue Errno::ECHILD
        # Already exited
      end
      @consumer_pids.clear
    end

    def build_dag_routing!
      # If this pipeline receives input from upstream, add :_input node and route it
      if @input_queue
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

      # Validate spawn strategies require preceding accumulator
      validate_spawn_strategies!
    end

    def validate_spawn_strategies!
      spawn_consumers = find_consumers_with_spawn_strategies

      spawn_consumers.each do |consumer_stage|
        # Check if there's an accumulator before this consumer
        upstream_stages = @dag.upstream(consumer_stage.name)
        has_accumulator = upstream_stages.any? do |upstream_name|
          stage = find_stage(upstream_name)
          stage && stage.accumulator?
        end

        unless has_accumulator
          raise Minigun::Error,
            "[Pipeline:#{@name}] Consumer '#{consumer_stage.name}' uses strategy '#{consumer_stage.strategy}' " \
            "but has no preceding accumulator stage. Add an accumulator stage before this consumer."
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
      first_non_producer = @stage_order.find { |s| !find_stage(s)&.producer? }

      if producers.size > 1 && first_non_producer
        # Multiple producers should all connect to the first non-producer, not to each other
        # BUT: only connect producers that don't already have explicit routing
        producers.each do |producer_name|
          # Skip if this producer already has explicit downstream edges
          if @dag.downstream(producer_name).empty?
            @dag.add_edge(producer_name, first_non_producer)
          end
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
        # PipelineStages should only connect to each other via explicit to: routing
        current_stage = find_stage(stage_name)
        next_stage_obj = find_stage(next_stage)
        if current_stage.is_a?(PipelineStage) && next_stage_obj.is_a?(PipelineStage)
          next
        end

        # Skip if this is a fan-out pattern (next_stage is a sibling)
        next if @dag.fan_out_siblings?(stage_name, next_stage)

        # Skip if any sibling already routes to next_stage
        # (indicates a converging pattern after fan-out)
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

