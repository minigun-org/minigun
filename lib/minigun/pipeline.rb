# frozen_string_literal: true

module Minigun
  # Pipeline represents a single data processing pipeline with stages
  # A Pipeline can be standalone or part of a multi-pipeline Task
  class Pipeline
    attr_reader :name, :config, :stages, :hooks, :dag, :input_queue, :output_queues

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

      @stages = {
        producer: nil,
        processor: [],
        accumulator: nil,
        consumer: []
      }

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

      # Copy stages (they're already Stage objects, so we keep references)
      new_pipeline.instance_variable_set(:@stages, {
        producer: @stages[:producer],
        processor: @stages[:processor].dup,
        accumulator: @stages[:accumulator],
        consumer: @stages[:consumer].dup
      })

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

      # Create a fresh DAG (edges will be rebuilt based on new stage order)
      new_dag = DAG.new
      @stage_order.each { |stage_name| new_dag.add_node(stage_name) }
      new_pipeline.instance_variable_set(:@dag, new_dag)
      new_pipeline.instance_variable_set(:@stage_order, @stage_order.dup)

      new_pipeline
    end

    # Add a stage to this pipeline
    def add_stage(type, name, options = {}, &block)
      # Insert processors before consumers (for inheritance support)
      if type == :processor && !@stages[:consumer].empty?
        # Find the first consumer in stage_order
        first_consumer_idx = @stage_order.index { |s| @stages[:consumer].any? { |c| c.name == s } }
        if first_consumer_idx
          @stage_order.insert(first_consumer_idx, name)
        else
          @stage_order << name
        end
      else
        @stage_order << name
      end

      # Rebuild DAG nodes to match stage_order
      @dag.instance_variable_set(:@nodes, @stage_order.dup)

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
              when :producer
                ProducerStage.new(name: name, block: block, options: options)
              when :processor
                ProcessorStage.new(name: name, block: block, options: options)
              when :accumulator
                AccumulatorStage.new(name: name, block: block, options: options)
              when :consumer
                ConsumerStage.new(name: name, block: block, options: options)
              else
                raise Minigun::Error, "Unknown stage type: #{type}"
              end

      # Store stage
      case type
      when :producer
        @stages[:producer] = stage
      when :processor
        @stages[:processor] << stage
      when :accumulator
        @stages[:accumulator] = stage
      when :consumer
        @stages[:consumer] << stage
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

      log_info "[Pipeline:#{@name}] Starting"

      # Build and validate DAG routing
      build_dag_routing!

      # Run before_run hooks
      @hooks[:before_run].each { |h| context.instance_eval(&h) }

      # Start internal queue (for stage-to-stage communication)
      @queue = SizedQueue.new(@config[:max_processes] * @config[:max_threads] * 2)

      # Start producer and accumulator threads
      producer_thread = start_producer
      accumulator_thread = start_accumulator

      # Wait for completion
      producer_thread.join
      accumulator_thread.join
      wait_all_consumers

      @job_end = Time.now

      log_info "[Pipeline:#{@name}] Finished in #{(@job_end - @job_start).round(2)}s"
      log_info "[Pipeline:#{@name}] Produced: #{@produced_count.value}, Accumulated: #{@accumulated_count}"

      # Run after_run hooks
      @hooks[:after_run].each { |h| context.instance_eval(&h) }

      @accumulated_count
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

    private

    def start_producer
      queue = @queue
      produced_count = @produced_count
      in_flight_count = @in_flight_count
      producer_stage = @stages[:producer]

      # Handle both internal producer and input from upstream pipeline
      has_internal_producer = producer_stage && producer_stage.block
      has_input_queue = @input_queue

      Thread.new do
        if has_internal_producer
          # Internal producer generates items
          producer_name = producer_stage.name
          log_info "[Pipeline:#{@name}][Producer] Starting"

          # Execute before hooks for this producer
          execute_stage_hooks(:before, producer_name)

          # Create emit method for producer
          emit_proc = proc do |item|
            in_flight_count.increment
            queue << [item, producer_name]
            produced_count.increment
          end

          # Bind emit to context
          @context.define_singleton_method(:emit, &emit_proc)

          # Run producer block
          @context.instance_eval(&producer_stage.block)

          log_info "[Pipeline:#{@name}][Producer] Done. Produced #{produced_count.value} items"

          # Execute after hooks for this producer
          execute_stage_hooks(:after, producer_name)
        end

        if has_input_queue
          # Consume from input queue (upstream pipeline)
          log_info "[Pipeline:#{@name}][Input] Waiting for upstream items"

          loop do
            item = @input_queue.pop
            break if item == :END_OF_QUEUE

            in_flight_count.increment
            queue << [item, :input]
            produced_count.increment
          end

          log_info "[Pipeline:#{@name}][Input] Upstream finished"
        end

        # Wait for all items to be processed
        sleep 0.01 while in_flight_count.value > 0

        # Signal end
        queue << :END_OF_QUEUE
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

            if target_stage.type == :accumulator
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
      # Execute before hooks for this stage
      execute_stage_hooks(:before, stage.name)

      result = if stage.respond_to?(:execute_with_emit)
        stage.execute_with_emit(@context, item)
      else
        stage.execute(@context, item)
        []
      end

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

      if @config[:use_ipc] && Process.respond_to?(:fork)
        fork_consumer_ipc(batch_map, output_items, total_items)
      elsif Process.respond_to?(:fork)
        fork_consumer_process(batch_map, output_items, total_items)
      else
        consume_in_threads(batch_map, output_items, total_items)
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
      log_info "[Pipeline:#{@name}][Consumer] Processing #{total_items} items (no fork)"
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

            if has_downstream
              # Create emit method for consumer to send to downstream pipelines
              emit_proc = proc do |emitted_item|
                mutex.synchronize { output_items << emitted_item }
              end
              @context.define_singleton_method(:emit, &emit_proc)
            end

            stage.execute(@context, item)
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
      if @dag.edges.values.all?(&:empty?)
        @dag.build_sequential!
      else
        fill_sequential_gaps_by_definition_order!
      end

      @dag.validate!
      validate_stages_exist!

      log_info "[Pipeline:#{@name}] DAG: #{@dag.topological_sort.join(' -> ')}"
    end

    def validate_stages_exist!
      @dag.nodes.each do |node_name|
        next if node_name == :input  # Special node for input queue

        unless find_stage(node_name)
          raise Minigun::Error, "[Pipeline:#{@name}] Routing references non-existent stage '#{node_name}'"
        end
      end

      # Validate spawn strategies require preceding accumulator
      validate_spawn_strategies!
    end

    def validate_spawn_strategies!
      spawn_strategies = [:spawn_thread, :spawn_fork, :spawn_ractor]

      @stages[:consumer].each do |consumer_stage|
        next unless spawn_strategies.include?(consumer_stage.options[:strategy])

        # Check if there's an accumulator before this consumer
        upstream_stages = @dag.upstream(consumer_stage.name)
        has_accumulator = upstream_stages.any? do |upstream_name|
          stage = find_stage(upstream_name)
          stage && stage.type == :accumulator
        end

        unless has_accumulator
          raise Minigun::Error,
            "[Pipeline:#{@name}] Consumer '#{consumer_stage.name}' uses strategy '#{consumer_stage.options[:strategy]}' " \
            "but has no preceding accumulator stage. Add an accumulator stage before this consumer."
        end
      end
    end

    def fill_sequential_gaps_by_definition_order!
      @stage_order.each_with_index do |stage_name, index|
        next if @dag.downstream(stage_name).any?
        next if index >= @stage_order.size - 1
        next if is_consumer_stage?(stage_name)

        next_stage = @stage_order[index + 1]
        @dag.add_edge(stage_name, next_stage)
      end
    end

    def is_consumer_stage?(stage_name)
      stage = find_stage(stage_name)
      stage && stage.is_a?(ConsumerStage)
    end

    def get_targets(stage_name)
      targets = @dag.downstream(stage_name)

      # If no targets and we have output queues, this is an output stage
      if targets.empty? && !@output_queues.empty? && !is_consumer_stage?(stage_name)
        # This item should be sent to output queues
        return [:output]
      end

      targets
    end

    def find_stage(name)
      return @stages[:producer] if @stages[:producer] && @stages[:producer].name == name
      return @stages[:accumulator] if @stages[:accumulator] && @stages[:accumulator].name == name

      consumer = @stages[:consumer].find { |c| c.name == name }
      return consumer if consumer

      @stages[:processor].find { |s| s.name == name }
    end

    def log_info(msg)
      Minigun.logger.info(msg)
    end

    def log_error(msg)
      Minigun.logger.error(msg)
    end
  end
end

