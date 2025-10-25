# frozen_string_literal: true

require_relative '../lib/minigun'
require 'securerandom'

# Converted from original PublisherBase to use Minigun
# This demonstrates the Producer → Accumulator → Fork Consumer pattern
class PublisherBase
  include Minigun::DSL

  attr_reader :job_start_at, :job_end_at, :models, :time_range
  attr_accessor :produced_count, :accumulated_count, :consumed_count

  # Configuration matching original - these are class-level defaults
  # Subclasses can override these as needed
  max_threads 10      # Matches Mongoid max_pool_size default
  max_processes 2     # Matches original default
  max_retries 10

  def initialize(models: nil,
                 start_time: nil,
                 end_time: nil,
                 max_processes: nil,
                 max_threads: nil,
                 max_retries: nil)
    @models = Array(models || default_models)
    @start_time = start_time
    @end_time = end_time
    @time_range = (@start_time..@end_time)

    @produced_count = 0
    @accumulated_count = 0
    @consumed_count = 0

    # Note: In Minigun, configuration is class-level
    # To override per-instance, you'd need to create a new subclass or use class methods
    # For this demo, we'll just use the class-level configuration
  end

  # Lifecycle hooks matching original PublisherBase
  before_run do
    @job_start_at = Time.now
    bootstrap!
    report_job_started
    before_job_start!
  end

  after_run do
    @job_end_at = Time.now
    report_job_finished
    after_job_finished!
  end

  # Pipeline-level fork hooks (apply to all consumers)
  before_fork do
    disconnect_database!
  end

  after_fork do
    reconnect_database!
  end

  # Producer: Generate [model, id] tuples for all models
  # Original: start_producer_thread + start_producer_model_thread
  producer :generate_ids do
    puts "[Producer] Starting ID generation for #{models.size} models"

    models.each do |model|
      puts "[Producer] Processing model: #{model}"

      # Stub: In real code, this would be model.where(updated_at: time_range).pluck(:_id)
      object_ids = generate_fake_ids(model, 1000) # Generate 1000 IDs per model

      object_ids.each do |id|
        emit([model, id])
        @produced_count += 1
      end

      puts "[Producer] #{model}: Produced #{object_ids.size} IDs"
    end

    puts "[Producer] Done. #{@produced_count} object IDs produced."
  end

  # Stage-specific hook: Called after producer finishes
  after :generate_ids do
    after_producer_finished!
  end

  # Consumer: Process batches in forked processes
  # Original: fork_consumer + consume_object_ids + start_consumer_thread
  # Uses fork_accumulate strategy for COW optimization
  fork_accumulate :consume_ids do |model, id|
    # In the original, this batches by model and processes in threads
    # Here we get individual items but can batch them ourselves
    consume_object(model, id)
    @consumed_count += 1
  end

  # Stage-specific fork hooks for this consumer
  before_fork :consume_ids do
    before_consumer_fork!
  end

  after_fork :consume_ids do
    after_consumer_fork!
  end

  # Subclass-specific methods (to be overridden)
  def consume_object(model, id)
    # Stub: Override in subclass
    # Original would call object.elastic_upsert! or similar
    puts "[Consumer] Processing #{model}##{id}"
  end

  def default_models
    # Stub: Override in subclass to return model list
    ['User', 'Post', 'Comment']
  end

  protected

  # Lifecycle hooks that can be overridden in subclasses
  def bootstrap!
    # Stub: Original would call Rails.application.eager_load!
    puts "[Bootstrap] Initializing..."
  end

  def before_job_start!
    # Can be overridden in subclass
  end

  def after_producer_finished!
    # Can be overridden in subclass
  end

  def before_consumer_fork!
    # Can be overridden in subclass
  end

  def after_consumer_fork!
    # Can be overridden in subclass
  end

  def after_job_finished!
    # Can be overridden in subclass
  end

  private

  def disconnect_database!
    # Stub: Original would call Mongoid.disconnect_clients
    puts "[Database] Disconnecting before fork..."
  end

  def reconnect_database!
    # Stub: Original would call Mongoid.reconnect_clients
    puts "[Database] Reconnecting after fork..."
  end

  def generate_fake_ids(model, count)
    # Stub: Generate fake MongoDB-style IDs
    count.times.map { |i| "#{model.downcase}_#{SecureRandom.hex(12)}" }
  end

  def report_job_started
    puts "\n#{job_name} started."
    puts job_info_message
  end

  def report_job_finished
    puts "\n#{job_name} finished."
    puts job_info_message(finished: true)
  end

  def job_name
    self.class.name
  end

  def job_info_message(finished: false)
    data = job_info_data(finished: finished)
    just = data.keys.map { |k| k.to_s.size }.max
    data.map do |k, v|
      "  #{k.to_s.ljust(just)}  #{v}"
    end.join("\n")
  end

  def job_info_data(finished: false)
    data = { job_start_at: format_time(@job_start_at) }

    if finished
      runtime = @job_end_at - @job_start_at
      rate = @accumulated_count / (runtime / 60.0)
      data[:job_end_at] = format_time(@job_end_at)
      data[:object_count] = "#{@accumulated_count} objects published"
      data[:job_runtime] = "#{runtime.round(2)} seconds"
      data[:job_rate] = "#{rate.round} objects / minute"
    end

    data[:query_start_at] = format_time(@start_time) || 'none'
    data[:query_end_at] = format_time(@end_time) || 'none'
    data[:max_processes] = self.class._minigun_task.config[:max_processes]
    data[:max_threads] = self.class._minigun_task.config[:max_threads]
    data[:max_retries] = self.class._minigun_task.config[:max_retries]
    data
  end

  def format_time(time)
    time&.strftime('%Y-%m-%d %H:%M:%S %z')
  end
end

