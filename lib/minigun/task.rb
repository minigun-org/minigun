# frozen_string_literal: true

module Minigun
  # Task executes the producer→accumulator→consumer(fork) pipeline pattern
  class Task
    attr_reader :config, :stages, :hooks

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
        consumer: nil
      }

      @hooks = {
        before_run: [],
        after_run: [],
        before_fork: [],
        after_fork: []
      }

      @produced_count = Concurrent::AtomicFixnum.new(0)
      @accumulated_count = 0
      @consumer_pids = []
    end

    # Set config value
    def set_config(key, value)
      @config[key] = value
    end

    # Add a stage
    def add_stage(type, name, &block)
      case type
      when :producer
        @stages[:producer] = { name: name, block: block }
      when :processor
        @stages[:processor] << { name: name, block: block }
      when :accumulator
        @stages[:accumulator] = { name: name, block: block }
      when :consumer
        @stages[:consumer] = { name: name, block: block }
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

      Thread.new do
        log_info "[Producer] Starting"

        # Create emit method for producer
        emit_proc = proc do |item|
          queue << item
          produced_count.increment
        end

        # Bind emit to context
        @context.define_singleton_method(:emit, &emit_proc)

        # Run producer block
        @context.instance_eval(&@stages[:producer][:block])

        # Signal end
        queue << :END_OF_QUEUE

        log_info "[Producer] Done. Produced #{produced_count.value} items"
      end
    end

    def start_accumulator
      Thread.new do
        log_info "[Accumulator] Starting"

        accumulator_map = Hash.new { |h, k| h[k] = [] }
        check_counter = 0

        loop do
          item = @queue.pop
          break if item == :END_OF_QUEUE

          # If we have processors, run them first
          processed_item = item
          @stages[:processor].each do |proc_stage|
            # Create emit for processor
            emitted_items = []
            emit_proc = proc { |i| emitted_items << i }
            @context.define_singleton_method(:emit, &emit_proc)

            # Run processor
            @context.instance_exec(processed_item, &proc_stage[:block])

            # Use emitted items or pass through
            processed_item = emitted_items.first if emitted_items.any?
          end

          # Accumulate by item class
          key = processed_item.class.name
          accumulator_map[key] << processed_item
          check_counter += 1

          # Check thresholds
          if check_counter % @config[:accumulator_check_interval] == 0
            check_and_fork(accumulator_map)
          end
        end

        # Process remaining
        fork_consumer(accumulator_map) unless accumulator_map.empty?

        @accumulated_count = accumulator_map.values.sum(&:size)

        log_info "[Accumulator] Done. Accumulated #{@accumulated_count} items"
      end
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

      batch_map.each do |_key, items|
        items.each do |item|
          Concurrent::Future.execute(executor: thread_pool) do
            if @stages[:consumer]
              @context.instance_exec(item, &@stages[:consumer][:block])
            end
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
  end
end

