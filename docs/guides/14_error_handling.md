# Error Handling

Learn how to handle errors gracefully in your Minigun pipelines.

## Quick Start

```ruby
class ResilientPipeline
  include Minigun::DSL

  attr_reader :errors

  def initialize
    @errors = Concurrent::Array.new
  end

  pipeline do
    processor :process do |item, output|
      begin
        result = risky_operation(item)
        output << result
      rescue => e
        @errors << { item: item, error: e.message, timestamp: Time.now }
        logger.error("Failed to process #{item}: #{e.message}")
      end
    end
  end

  after_run do
    unless @errors.empty?
      logger.warn("Pipeline completed with #{@errors.size} errors")
      write_error_log(@errors)
    end
  end
end
```

## Error Handling Strategies

### 1. Catch and Continue

Process errors without stopping the pipeline:

```ruby
processor :transform do |item, output|
  begin
    result = transform(item)
    output << result
  rescue TransformError => e
    logger.error("Transform failed for #{item}: #{e.message}")
    # Continue processing other items
  end
end
```

**Use when:**
- Individual item failures shouldn't stop the pipeline
- Partial success is acceptable
- Errors can be logged for later review

### 2. Catch and Log

Collect errors for analysis:

```ruby
class Pipeline
  include Minigun::DSL

  attr_reader :errors

  def initialize
    @errors = Concurrent::Array.new
  end

  pipeline do
    processor :process do |item, output|
      begin
        result = process(item)
        output << result
      rescue => e
        @errors << {
          item: item,
          error: e.class.name,
          message: e.message,
          backtrace: e.backtrace.first(5),
          timestamp: Time.now
        }
      end
    end
  end
end
```

### 3. Retry with Backoff

Retry failed operations with exponential backoff:

```ruby
processor :fetch do |url, output|
  retries = 0
  max_retries = 3

  begin
    response = HTTP.timeout(10).get(url)
    output << response.body
  rescue HTTP::TimeoutError, HTTP::ConnectionError => e
    retries += 1
    if retries <= max_retries
      sleep_time = 2 ** retries  # 2s, 4s, 8s
      logger.warn("Retry #{retries}/#{max_retries} for #{url} after #{sleep_time}s")
      sleep sleep_time
      retry
    else
      logger.error("Failed after #{max_retries} retries: #{url}")
      @errors << { url: url, error: e.message }
    end
  end
end
```

### 4. Circuit Breaker

Stop attempting operations that consistently fail:

```ruby
class Pipeline
  include Minigun::DSL

  def initialize
    @circuit_breaker = CircuitBreaker.new(
      failure_threshold: 5,
      timeout: 60
    )
  end

  pipeline do
    processor :call_api do |item, output|
      if @circuit_breaker.open?
        logger.warn("Circuit breaker open, skipping #{item}")
        @errors << { item: item, error: 'Circuit breaker open' }
        next
      end

      begin
        result = api_call(item)
        @circuit_breaker.record_success
        output << result
      rescue => e
        @circuit_breaker.record_failure
        @errors << { item: item, error: e.message }
      end
    end
  end
end

class CircuitBreaker
  def initialize(failure_threshold:, timeout:)
    @failure_threshold = failure_threshold
    @timeout = timeout
    @failures = 0
    @opened_at = nil
  end

  def open?
    return false if @opened_at.nil?
    return false if Time.now - @opened_at > @timeout
    true
  end

  def record_failure
    @failures += 1
    @opened_at = Time.now if @failures >= @failure_threshold
  end

  def record_success
    @failures = 0
    @opened_at = nil
  end
end
```

## Dead Letter Queue

Store failed items for later reprocessing:

```ruby
class PipelineWithDLQ
  include Minigun::DSL

  attr_reader :dead_letter_queue

  def initialize
    @dead_letter_queue = Concurrent::Array.new
  end

  pipeline do
    processor :process do |item, output|
      begin
        result = risky_operation(item)
        output << result
      rescue => e
        # Send to dead letter queue
        @dead_letter_queue << {
          item: item,
          error: e.message,
          timestamp: Time.now,
          attempt: item[:attempt] || 1
        }
        logger.error("Item sent to DLQ: #{item}")
      end
    end
  end

  after_run do
    # Write DLQ to file for later reprocessing
    unless @dead_letter_queue.empty?
      File.write(
        "dlq_#{Time.now.to_i}.json",
        JSON.pretty_generate(@dead_letter_queue.to_a)
      )
      logger.info("Wrote #{@dead_letter_queue.size} items to DLQ")
    end
  end
end
```

### Reprocessing from DLQ

```ruby
class DLQReprocessor
  include Minigun::DSL

  def initialize(dlq_file)
    @dlq_items = JSON.parse(File.read(dlq_file), symbolize_names: true)
  end

  pipeline do
    producer :dlq_items do |output|
      @dlq_items.each do |item|
        # Increment attempt counter
        item[:attempt] = (item[:attempt] || 1) + 1
        output << item
      end
    end

    processor :retry do |item, output|
      # Try again with increased timeout or different strategy
      result = retry_with_different_approach(item)
      output << result
    end
  end
end
```

## Error Recovery Patterns

### Pattern 1: Fallback Values

Provide default values for failed operations:

```ruby
processor :enrich do |user, output|
  begin
    profile = fetch_profile(user.id)
    output << user.merge(profile: profile)
  rescue ProfileNotFound
    # Fallback to basic profile
    output << user.merge(profile: { name: 'Unknown', avatar: '/default.png' })
  end
end
```

### Pattern 2: Alternative Data Source

Try alternative sources on failure:

```ruby
processor :fetch_data do |id, output|
  begin
    data = primary_source.fetch(id)
  rescue PrimarySourceError
    logger.warn("Primary source failed for #{id}, trying backup")
    data = backup_source.fetch(id)
  rescue BackupSourceError
    logger.error("Both sources failed for #{id}")
    @errors << { id: id, error: 'All sources failed' }
    next
  end

  output << data
end
```

### Pattern 3: Partial Processing

Process what you can, skip what fails:

```ruby
processor :transform do |batch, output|
  successful = []
  failed = []

  batch.each do |item|
    begin
      successful << transform_item(item)
    rescue => e
      failed << { item: item, error: e.message }
    end
  end

  output << successful unless successful.empty?
  @errors.concat(failed) unless failed.empty?
end
```

## Stage-Specific Error Handling

### Producer Errors

```ruby
producer :fetch_data do |output|
  begin
    Database.find_each do |record|
      output << record
    rescue => e
      logger.error("Failed to fetch record: #{e.message}")
      # Continue with next record
    end
  rescue DatabaseConnectionError => e
    logger.fatal("Database connection failed: #{e.message}")
    raise  # Fail the entire pipeline
  end
end
```

### Processor Errors

```ruby
processor :transform, threads: 10 do |item, output|
  begin
    result = expensive_transform(item)
    output << result
  rescue TransformError => e
    # Log and skip this item
    logger.warn("Transform failed for item #{item[:id]}: #{e.message}")
  rescue => e
    # Unexpected errors
    logger.error("Unexpected error: #{e.class} - #{e.message}")
    @errors << { item: item, error: e }
  end
end
```

### Consumer Errors

```ruby
consumer :save do |item|
  begin
    database.insert(item)
  rescue UniqueConstraintError
    # Already exists, ignore
    logger.debug("Item #{item[:id]} already exists")
  rescue DatabaseError => e
    # Serious error, should retry
    logger.error("Failed to save #{item[:id]}: #{e.message}")
    @errors << { item: item, error: e }
  end
end
```

## Monitoring Errors

### Error Metrics

```ruby
class MonitoredPipeline
  include Minigun::DSL

  def initialize
    @error_counts = Concurrent::Hash.new(0)
    @errors = Concurrent::Array.new
  end

  pipeline do
    processor :process do |item, output|
      begin
        result = process(item)
        output << result
      rescue => e
        @error_counts[e.class.name] += 1
        @errors << { item: item, error: e }
      end
    end
  end

  after_run do
    log_error_metrics
  end

  private

  def log_error_metrics
    total_errors = @errors.size
    return if total_errors.zero?

    logger.warn("Pipeline completed with #{total_errors} errors")
    logger.warn("Error breakdown:")
    @error_counts.each do |error_type, count|
      percentage = (count.to_f / total_errors * 100).round(1)
      logger.warn("  #{error_type}: #{count} (#{percentage}%)")
    end
  end
end
```

### Error Rate Alerting

```ruby
after_run do
  total_items = stats.items_processed
  error_rate = (@errors.size.to_f / total_items * 100).round(2)

  if error_rate > 5.0
    send_alert(
      severity: :high,
      message: "Pipeline error rate: #{error_rate}% (#{@errors.size}/#{total_items})"
    )
  elsif error_rate > 1.0
    send_alert(
      severity: :medium,
      message: "Pipeline error rate: #{error_rate}%"
    )
  end
end
```

## Error Reporting

### Structured Error Logs

```ruby
def log_error(item, error)
  error_data = {
    timestamp: Time.now.iso8601,
    pipeline: self.class.name,
    stage: current_stage_name,
    item: sanitize_item(item),
    error: {
      class: error.class.name,
      message: error.message,
      backtrace: error.backtrace.first(10)
    },
    context: {
      thread_id: Thread.current.object_id,
      process_id: Process.pid
    }
  }

  logger.error(JSON.generate(error_data))
end
```

### Error Aggregation

```ruby
after_run do
  unless @errors.empty?
    # Group errors by type
    grouped_errors = @errors.group_by { |e| e[:error] }

    # Write summary
    File.write('error_summary.json', JSON.pretty_generate({
      timestamp: Time.now.iso8601,
      total_errors: @errors.size,
      error_types: grouped_errors.transform_values(&:size),
      sample_errors: grouped_errors.transform_values { |errors| errors.first(3) }
    }))

    # Write full error log
    File.write('errors_full.jsonl', @errors.map(&:to_json).join("\n"))
  end
end
```

### External Error Tracking

```ruby
# Integration with Sentry, Rollbar, etc.
processor :process do |item, output|
  begin
    result = process(item)
    output << result
  rescue => e
    # Report to Sentry
    Sentry.capture_exception(e, extra: {
      pipeline: self.class.name,
      item_id: item[:id],
      stage: :process
    })

    @errors << { item: item, error: e }
  end
end
```

## Best Practices

### 1. Fail Fast for Configuration Errors

```ruby
before_run do
  # Validate configuration before processing
  raise ConfigurationError, "API key missing" unless ENV['API_KEY']
  raise ConfigurationError, "Database not configured" unless database_configured?

  # Test connections
  test_database_connection!
  test_api_connection!
end
```

### 2. Use Specific Exception Classes

```ruby
# ❌ Too broad
rescue => e
  # Catches everything, including bugs

# ✅ Specific
rescue HTTP::TimeoutError, HTTP::ConnectionError => e
  # Only catches expected network errors
```

### 3. Preserve Context

```ruby
rescue => e
  @errors << {
    item: item,
    error: e.message,
    error_class: e.class.name,
    stage: :transform,
    timestamp: Time.now,
    thread_id: Thread.current.object_id,
    backtrace: e.backtrace.first(10)
  }
end
```

### 4. Set Error Thresholds

```ruby
processor :process do |item, output|
  # Stop if too many errors
  if @errors.size > 1000
    logger.fatal("Error threshold exceeded (#{@errors.size} errors)")
    raise TooManyErrors, "Stopping pipeline due to excessive errors"
  end

  # Normal processing
  begin
    result = process(item)
    output << result
  rescue => e
    @errors << { item: item, error: e }
  end
end
```

### 5. Make Errors Observable

```ruby
# Collect errors for inspection
attr_reader :errors

# Provide error statistics
def error_summary
  {
    total: @errors.size,
    by_type: @errors.group_by { |e| e[:error] }.transform_values(&:size),
    by_stage: @errors.group_by { |e| e[:stage] }.transform_values(&:size)
  }
end
```

## Testing Error Handling

### Test Error Scenarios

```ruby
RSpec.describe MyPipeline do
  it 'handles transform errors gracefully' do
    pipeline = MyPipeline.new
    allow(pipeline).to receive(:transform).and_raise('Boom!')

    expect { pipeline.run }.not_to raise_error

    expect(pipeline.errors).not_to be_empty
    expect(pipeline.errors.first[:error]).to eq('Boom!')
  end

  it 'retries on transient errors' do
    pipeline = MyPipeline.new
    call_count = 0

    allow(pipeline).to receive(:fetch_data) do
      call_count += 1
      raise HTTP::TimeoutError if call_count < 3
      'success'
    end

    pipeline.run

    expect(call_count).to eq(3)  # Retried twice, succeeded third time
  end

  it 'stops after max retries' do
    pipeline = MyPipeline.new
    allow(pipeline).to receive(:fetch_data).and_raise(HTTP::TimeoutError)

    pipeline.run

    expect(pipeline.errors.first[:error]).to include('Failed after')
  end
end
```

## Real-World Example

```ruby
class RobustETLPipeline
  include Minigun::DSL

  attr_reader :errors, :retried_items

  def initialize
    @errors = Concurrent::Array.new
    @retried_items = Concurrent::Hash.new(0)
    @max_retries = 3
  end

  before_run do
    # Validate configuration
    raise "Database not configured" unless Database.connected?
    raise "API key missing" unless ENV['API_KEY']
  end

  pipeline do
    producer :extract do |output|
      begin
        SourceDB.find_each(batch_size: 1000) do |record|
          output << record
        end
      rescue DatabaseError => e
        logger.fatal("Failed to read from source: #{e.message}")
        raise  # Fail entire pipeline
      end
    end

    processor :transform, threads: 10 do |record, output|
      begin
        transformed = transform_with_retry(record)
        output << transformed
      rescue MaxRetriesExceeded => e
        @errors << {
          record_id: record.id,
          stage: :transform,
          error: e.message,
          attempts: @retried_items[record.id]
        }
      end
    end

    accumulator :batch, max_size: 500 do |batch, output|
      output << batch
    end

    consumer :load, threads: 4 do |batch|
      begin
        TargetDB.insert_many(batch)
      rescue UniqueConstraintError => e
        # Some records already exist, insert individually
        load_individually(batch)
      rescue DatabaseError => e
        logger.error("Failed to load batch: #{e.message}")
        @errors << { batch_size: batch.size, error: e.message }
      end
    end
  end

  after_run do
    log_results
    write_error_report if @errors.any?
  end

  private

  def transform_with_retry(record)
    retries = @retried_items[record.id]

    begin
      transform(record)
    rescue TransformError => e
      if retries < @max_retries
        @retried_items[record.id] += 1
        sleep(2 ** retries)  # Exponential backoff
        retry
      else
        raise MaxRetriesExceeded, "Failed after #{@max_retries} attempts"
      end
    end
  end

  def load_individually(batch)
    batch.each do |record|
      begin
        TargetDB.insert(record)
      rescue UniqueConstraintError
        # Skip duplicates
        logger.debug("Record #{record.id} already exists")
      rescue => e
        @errors << { record_id: record.id, error: e.message }
      end
    end
  end

  def log_results
    total = stats.items_processed
    error_count = @errors.size
    success_count = total - error_count
    success_rate = (success_count.to_f / total * 100).round(2)

    logger.info("Pipeline completed:")
    logger.info("  Total: #{total}")
    logger.info("  Success: #{success_count} (#{success_rate}%)")
    logger.info("  Errors: #{error_count}")
  end

  def write_error_report
    File.write("errors_#{Time.now.to_i}.json", JSON.pretty_generate({
      timestamp: Time.now.iso8601,
      pipeline: self.class.name,
      total_errors: @errors.size,
      errors: @errors.to_a
    }))
  end
end

class MaxRetriesExceeded < StandardError; end
```

## Key Takeaways

**Error Handling Strategies:**
- Catch and continue for non-critical errors
- Retry with backoff for transient failures
- Use dead letter queues for failed items
- Implement circuit breakers for consistently failing operations

**Best Practices:**
- Fail fast for configuration errors
- Use specific exception classes
- Preserve error context
- Make errors observable
- Set error thresholds
- Test error scenarios

**Monitoring:**
- Collect error metrics
- Alert on error rates
- Write structured error logs
- Integrate with error tracking services

## Next Steps

- [Testing](12_testing.md) - Testing error scenarios
- [Performance Tuning](11_performance_tuning.md) - Optimize error handling
- [Monitoring](07_monitoring.md) - Monitor error rates with HUD

---

**Handle errors gracefully** to build resilient, production-ready pipelines.
