# frozen_string_literal: true

require 'minigun'

# Base class for Minigun-based publishers
# This provides a similar interface to the original PublisherBase
# but uses the Minigun gem under the hood
class MinigunPublisherBase
  include Minigun::DSL

  ACCUMULATOR_MAX_SINGLE_QUEUE = 2000
  ACCUMULATOR_MAX_ALL_QUEUES = 4000
  DEFAULT_MAX_RETRIES = 10
  CONSUMER_THREAD_BATCH_SIZE = 200
  CONSUMER_QUERY_BATCH_SIZE = 200

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
    @max_processes_override = max_processes
    @max_threads_override = max_threads
    @max_retries_override = max_retries || DEFAULT_MAX_RETRIES
    @use_analytics_node = !!use_analytics_node

    @produced_count = 0
    @consumed_count = 0
    @accumulated_count = 0
    @producer_mutex = Mutex.new
    @consumer_mutex = Mutex.new
  end

  def perform
    @job_start_at = Time.current
    report_job_started
    before_job_start!

    # Run the minigun pipeline
    run

    @job_end_at = Time.current
    report_job_finished
    after_job_finished!
  end

  # Define the pipeline structure
  pipeline do
    # Producer stage: Fetch IDs from models
    producer :producer do
      producer_semaphore = Concurrent::Semaphore.new(max_threads_value)
      producer_threads = []

      models.each do |model|
        producer_semaphore.acquire
        producer_threads << Thread.new do
          begin
            model_name = model.to_s.demodulize
            Rails.logger.info { "[Producer] #{model_name}: Starting..." }

            time_range_in_batches(model).each do |range|
              count = produce_model(model, range)
              Rails.logger.info { "[Producer] #{model_name}: Produced #{count} IDs" }
            end
          ensure
            producer_semaphore.release
          end
        end
      end

      producer_threads.each(&:join)
      after_producer_finished!
    end

    # Accumulator stage: Batch IDs by model
    accumulator :accumulator do |model_id_pair|
      model, id = model_id_pair
      @accumulator_map ||= Hash.new { |h, k| h[k] = Set.new }
      @accumulator_map[model] << id
      @accumulated_count += 1

      # Check if we should emit
      should_emit = false
      batch_to_emit = nil

      # Check single queue threshold
      if @accumulator_map[model].size >= ACCUMULATOR_MAX_SINGLE_QUEUE
        batch_to_emit = { model => @accumulator_map.delete(model) }
        should_emit = true
      # Check total threshold
      elsif @accumulator_map.values.sum(&:size) >= ACCUMULATOR_MAX_ALL_QUEUES
        batch_to_emit = @accumulator_map.dup
        @accumulator_map.clear
        should_emit = true
      end

      emit(batch_to_emit) if should_emit
    end

    # Consumer stage: Process batches in forked processes
    cow_fork :consumer, processes: max_processes_value do |object_map|
      before_consumer_fork!

      # Process in this forked child
      consumer_semaphore = Concurrent::Semaphore.new(max_threads_value)
      consumer_threads = []
      consumed = 0

      object_map.each do |model, object_ids|
        object_ids.to_a.each_slice(CONSUMER_THREAD_BATCH_SIZE) do |batch|
          consumer_semaphore.acquire
          consumer_threads << Thread.new do
            begin
              count = consume_batch(model, batch)
              @consumer_mutex.synchronize { consumed += count }
            ensure
              consumer_semaphore.release
            end
          end
        end
      end

      consumer_threads.each(&:join)
      after_consumer_finished!

      Rails.logger.info { "[Consumer] Processed #{consumed} objects" }
    end
  end

  # Hooks
  before_run do
    bootstrap!
  end

  before_fork do
    # Disconnect database connections before forking
    if defined?(Mongoid)
      Mongoid.disconnect_clients
    elsif defined?(ActiveRecord)
      ActiveRecord::Base.connection_handler.clear_all_connections!
    end

    before_consumer_fork!
  end

  after_fork do
    # Reconnect database connections after forking
    if defined?(Mongoid)
      Mongoid.reconnect_clients
    elsif defined?(ActiveRecord)
      ActiveRecord::Base.connection_handler.establish_connection
    end

    after_consumer_fork!
  end

  private

  # Methods to be overridden in subclasses
  def default_models
    raise NotImplementedError, "Subclass must implement #default_models"
  end

  def consume_object(object)
    raise NotImplementedError, "Subclass must implement #consume_object"
  end

  # Helper methods
  def models
    @models ||= (@raw_models || default_models).map { |model| load_model(model) }
  end

  def load_model(model)
    return model if model.is_a?(Module)
    model = "::Vesper::Table::#{model}" unless model.include?(':')
    Object.const_get(model)
  end

  def produce_model(model, range)
    count = 0
    model_base_scope(model).where(updated_at: range).pluck_each(:_id) do |id|
      emit([model, id.to_s.freeze].freeze)
      @producer_mutex.synchronize { @produced_count += 1 }
      count += 1
    end
    count
  end

  def model_base_scope(model)
    scope = model.unscoped
    # Add franchise filtering if needed
    if franchise_ids.present?
      # Implementation depends on model relationships
      scope = scope.where(franchise_id: franchise_ids.first) if franchise_ids.size == 1
      scope = scope.any_in(franchise_id: franchise_ids) if franchise_ids.size > 1
    end
    scope
  end

  def consume_batch(model, object_ids)
    count = 0
    consumer_scope(model, object_ids).each do |object|
      consume_object(object)
      count += 1
    rescue StandardError => e
      Rails.logger.error { "[Consumer] Error processing #{model}: #{e.message}" }
      Bugsnag.notify(e) if defined?(Bugsnag)
    end
    count
  end

  def consumer_scope(model, object_ids)
    model.unscoped.any_in(_id: object_ids)
  end

  def time_range
    @time_range ||= begin
      start = @start_time || Time.current - 1.hour
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

  def max_processes_value
    @max_processes_override || ENV.fetch('MAX_PROCESSES', 2).to_i
  end

  def max_threads_value
    @max_threads_override || ENV.fetch('MAX_THREADS', 5).to_i
  end

  def max_retries_value
    @max_retries_override
  end

  def franchise_ids
    return @franchise_ids if defined?(@franchise_ids)
    @franchise_ids = @raw_franchise_ids
  end

  def bootstrap!
    # Override in subclass if needed
  end

  def before_job_start!
    # Override in subclass if needed
  end

  def after_producer_finished!
    # Override in subclass if needed
  end

  def before_consumer_fork!
    # Override in subclass if needed
  end

  def after_consumer_fork!
    # Override in subclass if needed
  end

  def after_consumer_finished!
    # Override in subclass if needed
  end

  def after_job_finished!
    # Override in subclass if needed
  end

  def report_job_started
    Rails.logger.info { "#{self.class.name} started" }
    Rails.logger.info { "  max_processes: #{max_processes_value}" }
    Rails.logger.info { "  max_threads: #{max_threads_value}" }
    Rails.logger.info { "  time_range: #{time_range.begin}..#{time_range.end}" }
  end

  def report_job_finished
    runtime = job_end_at - job_start_at
    rate = @accumulated_count / (runtime / 60.0)

    Rails.logger.info { "#{self.class.name} finished" }
    Rails.logger.info { "  runtime: #{runtime.round(2)}s" }
    Rails.logger.info { "  produced: #{@produced_count}" }
    Rails.logger.info { "  accumulated: #{@accumulated_count}" }
    Rails.logger.info { "  rate: #{rate.round(2)} items/min" }
  end
end

