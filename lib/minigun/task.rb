# frozen_string_literal: true

module Minigun
  # Task executes the producer→accumulator→consumer(fork) pipeline pattern
  class Task
    attr_reader :config, :stages, :hooks, :dag

    def initialize
      @config = {
        max_threads: 5,
        max_processes: 2,
        max_retries: 3,
        accumulator_max_single: 2000,
        accumulator_max_all: 4000,
        accumulator_check_interval: 100
      }

      @stages = {
        producer: nil,
        processor: [],
        accumulator: nil,
        consumer: []  # Support multiple consumers
      }

      @hooks = {
        before_run: [],
        after_run: [],
        before_fork: [],
        after_fork: []
      }

      @dag = DAG.new  # Directed Acyclic Graph for stage routing
      @stage_order = []  # Track order stages were defined

      @produced_count = Concurrent::AtomicFixnum.new(0)
      @in_flight_count = Concurrent::AtomicFixnum.new(0)  # Track items being processed
      @accumulated_count = 0
      @consumer_pids = []
    end

    # Set config value
    def set_config(key, value)
      @config[key] = value
    end

    # Add a stage
    def add_stage(type, name, options = {}, &block)
      # Track stage definition order
      @stage_order << name

      # Add node to DAG
      @dag.add_node(name)

      # Extract routing information
      to_targets = options.delete(:to)
      if to_targets
        Array(to_targets).each { |target| @dag.add_edge(name, target) }
      end

      # Store stage
      case type
      when :producer
        @stages[:producer] = { name: name, block: block, options: options }
      when :processor
        @stages[:processor] << { name: name, block: block, options: options }
      when :accumulator
        @stages[:accumulator] = { name: name, block: block, options: options }
      when :consumer
        @stages[:consumer] << { name: name, block: block, options: options }
      end
    end

    # Add a hook
    def add_hook(type, &block)
      @hooks[type] ||= []
      @hooks[type] << block
    end

    # Run the pipeline
    def run(context)
      @context = context
      @job_start = Time.now

      log_info "Starting Minigun pipeline"

      # Build and validate DAG routing
      build_dag_routing!

      # Run before_run hooks
      @hooks[:before_run].each { |h| context.instance_eval(&h) }

      # Start producer and accumulator threads
      @queue = SizedQueue.new(@config[:max_processes] * @config[:max_threads] * 2)

      producer_thread = start_producer
      accumulator_thread = start_accumulator

      # Wait for completion
      producer_thread.join
      accumulator_thread.join
      wait_all_consumers

      @job_end = Time.now

      log_info "Finished in #{(@job_end - @job_start).round(2)}s"
      log_info "Produced: #{@produced_count.value}, Accumulated: #{@accumulated_count}"

      # Run after_run hooks
      @hooks[:after_run].each { |h| context.instance_eval(&h) }

      @accumulated_count
    end

    private

    def start_producer
      queue = @queue
      produced_count = @produced_count
      in_flight_count = @in_flight_count
      producer_name = @stages[:producer][:name]

      Thread.new do
        log_info "[Producer] Starting"

        # Create emit method for producer
        emit_proc = proc do |item|
          in_flight_count.increment  # Track in-flight items
          queue << [item, producer_name]
          produced_count.increment
        end

        # Bind emit to context
        @context.define_singleton_method(:emit, &emit_proc)

        # Run producer block
        @context.instance_eval(&@stages[:producer][:block])

        log_info "[Producer] Done. Produced #{produced_count.value} items"

        # Wait for all items to be processed
        sleep 0.01 while in_flight_count.value > 0

        # Now signal end
        queue << :END_OF_QUEUE
      end
    end

    def start_accumulator
      Thread.new do
        log_info "[Accumulator] Starting"

        # Track items by consumer name for batching
        consumer_queues = Hash.new { |h, k| h[k] = [] }
        check_counter = 0

        loop do
          item_data = @queue.pop
          break if item_data == :END_OF_QUEUE

          # item_data is [item, source_stage_name]
          item, source_stage = item_data

          # Get routing targets for this source
          targets = get_targets(source_stage)

          # Decrement for the consumed item (once per item, not per target)
          @in_flight_count.decrement

          # Process through each target
          targets.each do |target_name|
            target_stage = find_stage(target_name)
            next unless target_stage

            # Check if this is a terminal stage (consumer)
            if @dag.terminal?(target_name)
              # Accumulate by consumer name for later batch processing
              consumer_queues[target_name] << { item: item, stage: target_stage }
              check_counter += 1

              # Check thresholds
              if check_counter % @config[:accumulator_check_interval] == 0
                check_and_fork(consumer_queues)
              end
            else
              # It's a processor - execute and route outputs
              emitted_items = execute_stage(target_stage, item)

              # Increment for each emitted item and put in queue
              emitted_items.each do |emitted_item|
                @in_flight_count.increment
                @queue << [emitted_item, target_name]
              end
            end
          end
        end

        # Process remaining
        fork_consumer(consumer_queues) unless consumer_queues.empty?

        @accumulated_count = consumer_queues.values.sum(&:size)

        log_info "[Accumulator] Done. Accumulated #{@accumulated_count} items"
      end
    end

    # Execute a stage and return emitted items
    def execute_stage(stage, item)
      emitted_items = []
      emit_proc = proc { |i| emitted_items << i }
      @context.define_singleton_method(:emit, &emit_proc)

      # Run stage block
      @context.instance_exec(item, &stage[:block])

      # Return only explicitly emitted items
      emitted_items
    end

    def check_and_fork(accumulator_map)
      # Check single queue threshold
      accumulator_map.each do |key, items|
        if items.size >= @config[:accumulator_max_single]
          fork_consumer({ key => accumulator_map.delete(key) })
        end
      end

      # Check total threshold
      total = accumulator_map.values.sum(&:size)
      if total >= @config[:accumulator_max_all]
        fork_consumer(accumulator_map.dup)
        accumulator_map.clear
      end
    end

    def fork_consumer(batch_map)
      total_items = batch_map.values.sum(&:size)

      # Check if fork is supported
      if Process.respond_to?(:fork)
        fork_consumer_process(batch_map, total_items)
      else
        # Fallback to threading on Windows
        consume_in_threads(batch_map, total_items)
      end
    end

    def fork_consumer_process(batch_map, total_items)
      wait_for_consumer_slot

      log_info "[Fork] Forking to process #{total_items} items"

      # Run before_fork hooks
      @hooks[:before_fork].each { |h| @context.instance_eval(&h) }

      # Trigger GC before fork
      GC.start if @consumer_pids.empty? || @consumer_pids.size % 4 == 0

      pid = fork do
        # In child process
        @pid = Process.pid

        # Run after_fork hooks
        @hooks[:after_fork].each { |h| @context.instance_eval(&h) }

        log_info "[Consumer:#{@pid}] Started"

        # Process items
        consume_batch(batch_map)

        log_info "[Consumer:#{@pid}] Done"

        exit! 0
      end

      @consumer_pids << pid
    end

    def consume_in_threads(batch_map, total_items)
      log_info "[Consumer] Processing #{total_items} items (no fork)"
      consume_batch(batch_map)
    end

    def consume_batch(batch_map)
      # Process items with thread pool
      thread_pool = Concurrent::FixedThreadPool.new(@config[:max_threads])
      processed = Concurrent::AtomicFixnum.new(0)

      batch_map.each do |_consumer_name, item_data_array|
        item_data_array.each do |item_data|
          Concurrent::Future.execute(executor: thread_pool) do
            item = item_data[:item]
            stage = item_data[:stage]
            @context.instance_exec(item, &stage[:block])
            processed.increment
          end
        end
      end

      # Shutdown pool
      thread_pool.shutdown
      thread_pool.wait_for_termination(30)

      log_info "[Consumer] Processed #{processed.value} items"
    end

    def wait_for_consumer_slot
      return if @consumer_pids.size < @config[:max_processes]

      # Wait for one to finish
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

    def log_info(msg)
      Minigun.logger.info(msg)
    end

    # Build and validate DAG routing
    def build_dag_routing!
      # If no explicit routing was defined, build sequential connections
      if @dag.edges.values.all?(&:empty?)
        @dag.build_sequential!
      else
        # Fill in sequential gaps based on stage definition order
        fill_sequential_gaps_by_definition_order!
      end

      # Validate the DAG
      @dag.validate!

      # Validate that all nodes in DAG have corresponding stages
      validate_stages_exist!

      log_info "DAG: #{@dag}"
    end

    # Validate that all DAG nodes have corresponding stage definitions
    def validate_stages_exist!
      @dag.nodes.each do |node_name|
        unless find_stage(node_name)
          raise Minigun::Error, "Routing references non-existent stage '#{node_name}'"
        end
      end
    end

    # Fill sequential gaps using the order stages were defined, not DAG node order
    def fill_sequential_gaps_by_definition_order!
      @stage_order.each_with_index do |stage_name, index|
        # Skip if already has downstream, or if it's the last stage
        next if @dag.downstream(stage_name).any?
        next if index >= @stage_order.size - 1

        # Don't connect consumers to anything (they're always terminal nodes)
        next if is_consumer_stage?(stage_name)

        next_stage = @stage_order[index + 1]
        @dag.add_edge(stage_name, next_stage)
      end
    end

    # Check if a stage is a consumer
    def is_consumer_stage?(stage_name)
      @stages[:consumer].any? { |c| c[:name] == stage_name }
    end

    # Get all stages that should receive items from a given stage
    def get_targets(stage_name)
      @dag.downstream(stage_name)
    end

    # Find a stage by name
    def find_stage(name)
      return @stages[:producer] if @stages[:producer] && @stages[:producer][:name] == name
      return @stages[:accumulator] if @stages[:accumulator] && @stages[:accumulator][:name] == name

      consumer = @stages[:consumer].find { |c| c[:name] == name }
      return consumer if consumer

      @stages[:processor].find { |s| s[:name] == name }
    end
  end
end

