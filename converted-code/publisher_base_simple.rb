# frozen_string_literal: true

require 'concurrent'

# Simplified publisher base that follows the original pattern
# This is a standalone implementation that doesn't rely on the complex Minigun DSL
class PublisherBaseSimple
  ACCUMULATOR_MAX_SINGLE_QUEUE = 2000
  ACCUMULATOR_MAX_ALL_QUEUES = 4000
  ACCUMULATOR_CHECK_INTERVAL = 100
  CONSUMER_THREAD_BATCH_SIZE = 200
  CONSUMER_QUERY_BATCH_SIZE = 200
  DEFAULT_MAX_RETRIES = 10

  attr_reader :job_start_at, :job_end_at

  def initialize(models: nil,
                 start_time: nil,
                 end_time: nil,
                 max_processes: nil,
                 max_threads: nil,
                 max_retries: nil,
                 franchise_ids: nil,
                 use_analytics_node: false)
    @raw_models = Array(models) if models
    @raw_franchise_ids = Array(franchise_ids).map(&:to_s).uniq if franchise_ids&.any?
    @start_time = start_time
    @end_time = end_time
    @max_processes_arg = max_processes
    @max_threads_arg = max_threads
    @max_retries_arg = max_retries
    @use_analytics_node = !!use_analytics_node

    @produced_count = 0
    @accumulated_count = 0
    @consumer_pids = []
    @producer_mutex = Mutex.new
  end

  def perform
    @job_start_at = Time.current
    report_job_started
    before_job_start!

    producer_thread = start_producer_thread
    accumulator_thread = start_accumulator_thread

    producer_thread.join
    accumulator_thread.join

    wait_all_consumer_processes

    @job_end_at = Time.current
    report_job_finished
    after_job_finished!
  end

  private

  def start_producer_thread
    @object_id_queue = SizedQueue.new(max_processes * max_threads * 2)

    Thread.new do
      log_info "[Producer] Started"

      producer_semaphore = Concurrent::Semaphore.new(max_threads)
      producer_threads = []

      models.each do |model|
        producer_semaphore.acquire
        producer_threads << Thread.new do
          begin
            produce_for_model(model)
          ensure
            producer_semaphore.release
            GC.start
          end
        end
      end

      producer_threads.each(&:join)
      after_producer_finished!

      @object_id_queue << :END_OF_QUEUE
      log_info "[Producer] Done. #{@produced_count} IDs produced"
    end
  end

  def produce_for_model(model)
    model_name = model.to_s.split('::').last
    log_info "[Producer] #{model_name}: Starting"

    time_range_in_batches(model).each do |range|
      count = produce_model(model, range)
      log_info "[Producer] #{model_name}: Produced #{count} IDs for #{format_time_range(range)}"
    end
  end

  def produce_model(model, range)
    count = 0
    model_base_scope(model).where(updated_at: range).pluck_each(:_id) do |id|
      @object_id_queue << [model, id.to_s.freeze].freeze
      @producer_mutex.synchronize { @produced_count += 1 }
      count += 1
    end
    count
  end

  def start_accumulator_thread
    Thread.new do
      log_info "[Accumulator] Started"
      accumulator_map = Hash.new { |h, k| h[k] = Set.new }

      i = 0
      until (item = @object_id_queue.pop) == :END_OF_QUEUE
        model, id = item
        accumulator_map[model] << id
        i += 1

        check_accumulator(accumulator_map) if i >= ACCUMULATOR_MAX_SINGLE_QUEUE && i % ACCUMULATOR_CHECK_INTERVAL == 0
      end

      # Process remaining items
      unless accumulator_map.empty?
        consume_object_ids(accumulator_map)
        @accumulated_count += accumulator_map.values.sum(&:size)
      end

      log_info "[Accumulator] Done. #{@accumulated_count} IDs accumulated"
    end
  end

  def check_accumulator(accumulator_map)
    # Fork if any single queue exceeds threshold
    accumulator_map.each do |model, ids|
      next unless ids.size >= ACCUMULATOR_MAX_SINGLE_QUEUE

      fork_consumer({ model => accumulator_map.delete(model) })
      @accumulated_count += ids.size
    end

    # Fork if total exceeds threshold
    total_size = accumulator_map.values.sum(&:size)
    if total_size >= ACCUMULATOR_MAX_ALL_QUEUES
      fork_consumer(accumulator_map.dup)
      accumulator_map.clear
      @accumulated_count += total_size
    end
  end

  def fork_consumer(object_map)
    wait_max_consumer_processes
    before_consumer_fork!

    log_info "[Consumer] Forking"
    GC.start if @consumer_pids.empty? || @consumer_pids.size % 4 == 0

    @consumer_pids << fork do
      after_consumer_fork!
      pid = Process.pid
      log_info "[Consumer PID #{pid}] Started"

      consume_object_ids(object_map)

      log_info "[Consumer PID #{pid}] Done"
    end
  end

  def consume_object_ids(object_map)
    consumer_semaphore = Concurrent::Semaphore.new(max_threads)
    consumer_threads = []
    consumed_count = Concurrent::AtomicFixnum.new(0)

    object_map.each do |model, object_ids|
      object_ids.to_a.uniq.each_slice(CONSUMER_THREAD_BATCH_SIZE) do |batch|
        consumer_semaphore.acquire
        consumer_threads << Thread.new do
          begin
            count = consume_batch(model, batch)
            consumed_count.increment(count)
          ensure
            consumer_semaphore.release
          end
        end
      end
    end

    consumer_threads.each(&:join)
    after_consumer_finished!

    log_info "[Consumer] Processed #{consumed_count.value} objects"
  end

  def consume_batch(model, object_ids)
    count = 0

    object_ids.each_slice(CONSUMER_QUERY_BATCH_SIZE) do |batch|
      consumer_scope(model, batch).each do |object|
        consume_object(object)
        count += 1
      rescue StandardError => e
        log_error "[Consumer] Error processing #{model} #{object&._id}: #{e.message}"
        notify_error(e, model: model, object_id: object&._id)
      end
    end

    count
  end

  def consumer_scope(model, object_ids)
    model.unscoped.any_in(_id: object_ids)
  end

  def wait_max_consumer_processes
    return if @consumer_pids.size < max_processes

    begin
      pid = Process.wait
      @consumer_pids.delete(pid)
    rescue Errno::ECHILD
      # No child processes
    end
  end

  def wait_all_consumer_processes
    @consumer_pids.each do |pid|
      Process.wait(pid)
      @consumer_pids.delete(pid)
    rescue Errno::ECHILD
      @consumer_pids.delete(pid)
    end
  end

  # Methods to override in subclasses
  def default_models
    raise NotImplementedError
  end

  def consume_object(object)
    raise NotImplementedError
  end

  # Helper methods
  def models
    @models ||= (@raw_models || default_models).map { |m| load_model(m) }
  end

  def load_model(model)
    return model if model.is_a?(Module)
    model = "::Vesper::Table::#{model}" unless model.include?(':')
    Object.const_get(model)
  end

  def model_base_scope(model)
    scope = model.unscoped

    if franchise_ids.present?
      if franchise_ids.size == 1
        scope = scope.where(franchise_id: franchise_ids.first)
      else
        scope = scope.any_in(franchise_id: franchise_ids)
      end
    end

    scope
  end

  def franchise_ids
    return @franchise_ids if defined?(@franchise_ids)
    @franchise_ids = @raw_franchise_ids
  end

  def time_range
    @time_range ||= begin
      start = @start_time || (Time.current - 1.hour)
      finish = @end_time || Time.current
      start..finish
    end
  end

  def time_range_in_batches(model)
    ranges = []
    current = time_range.begin
    batch_size = 1.hour

    while current < time_range.end
      next_time = [current + batch_size, time_range.end].min
      ranges << (current..next_time)
      current = next_time
    end

    ranges
  end

  def max_processes
    @max_processes_arg || ENV.fetch('MAX_PROCESSES', 2).to_i
  end

  def max_threads
    @max_threads_arg || ENV.fetch('MAX_THREADS', 5).to_i
  end

  def max_retries
    @max_retries_arg || DEFAULT_MAX_RETRIES
  end

  # Hooks (override in subclass)
  def before_job_start!; end
  def after_producer_finished!; end
  def before_consumer_fork!
    if defined?(Mongoid)
      Mongoid.disconnect_clients
    end
  end

  def after_consumer_fork!
    if defined?(Mongoid)
      Mongoid.reconnect_clients
    end
  end

  def after_consumer_finished!; end
  def after_job_finished!; end

  # Logging
  def log_info(message)
    if defined?(Rails)
      Rails.logger.info(message)
    else
      puts message
    end
  end

  def log_error(message)
    if defined?(Rails)
      Rails.logger.error(message)
    else
      warn message
    end
  end

  def notify_error(error, metadata = {})
    if defined?(Bugsnag)
      Bugsnag.notify(error) { |r| r.add_metadata('publisher', metadata) }
    end
  end

  def report_job_started
    log_info "#{self.class.name} started"
    log_info "  max_processes: #{max_processes}"
    log_info "  max_threads: #{max_threads}"
    log_info "  time_range: #{format_time_range(time_range)}"
  end

  def report_job_finished
    runtime = job_end_at - job_start_at
    rate = @accumulated_count / [runtime / 60.0, 0.01].max

    log_info "#{self.class.name} finished"
    log_info "  runtime: #{runtime.round(2)}s"
    log_info "  produced: #{@produced_count}"
    log_info "  accumulated: #{@accumulated_count}"
    log_info "  rate: #{rate.round(2)} items/min"
  end

  def format_time_range(range)
    "#{range.begin.strftime('%Y-%m-%d %H:%M:%S')}..#{range.end.strftime('%Y-%m-%d %H:%M:%S')}"
  end
end

