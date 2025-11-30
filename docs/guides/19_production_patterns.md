# Production Patterns for Reliability

This guide covers recommended patterns for running Minigun pipelines reliably in production. It addresses common questions about fault tolerance, high availability, and recovery.

## Understanding Minigun's Architecture

Before discussing reliability patterns, it's important to understand what happens when different components fail:

### Failure Modes

| Component | Failure Impact | Built-in Recovery |
|-----------|----------------|-------------------|
| **Worker thread** | Items in that thread may fail | Logged, pipeline continues |
| **IPC Fork worker** | Items in that worker may fail | Optional restart policy |
| **Cluster worker** | Items assigned to worker may fail | `at_least_once` delivery retries |
| **Coordinator/Pipeline** | **Entire job fails** | None - must restart externally |

The key insight: **Worker failures are recoverable. Pipeline/coordinator failures require external restart.**

## Pattern 1: Reliable Worker Processing

### IPC Fork with Restart Policy

For CPU-intensive work that might crash workers:

```ruby
class ReliableProcessor
  include Minigun::DSL

  pipeline do
    produce_each :items, -> { load_items_from_database }

    # Workers restart automatically on abnormal exit
    in_ipc_forks(4, restart_policy: :transient, max_restarts: 3) do
      processor :risky_work do |item, output|
        result = potentially_crashing_operation(item)
        output << result
      end
    end

    consumer :save do |result|
      save_to_database(result)
    end
  end
end
```

**Restart policies:**
- `:never` (default) - Don't restart failed workers
- `:transient` - Restart workers that exit abnormally (signal or non-zero exit)
- `:permanent` - Always restart workers that exit

**Rate limiting:**
- `max_restarts: 3` - Maximum restarts per worker
- `restart_window: 60` - Time window (seconds) for counting restarts

### Cluster with At-Least-Once Delivery

For distributed processing where item loss is unacceptable:

```ruby
class ReliableCluster
  include Minigun::DSL

  pipeline do
    produce_each :items, -> { load_items }

    in_cluster(
      coordinator_uri: 'druby://0.0.0.0:9000',
      min_workers: 2,
      delivery_mode: :at_least_once,  # Retry failed items
      max_retries: 3
    ) do
      processor :distributed_work do |item, output|
        # Must be idempotent! Items may be processed multiple times
        result = process_idempotently(item)
        output << result
      end
    end

    consumer :save do |result|
      save_result(result)
    end
  end
end
```

**Important:** With `at_least_once`, your processors MUST be idempotent (safe to run multiple times on the same item).

## Pattern 2: Persistent Input Sources

The most important reliability pattern: **use persistent input sources**.

### Database-Backed Producer

```ruby
class DatabasePipeline
  include Minigun::DSL

  pipeline do
    producer :pending_items do |output|
      # Only fetch unprocessed items
      Item.where(status: 'pending').find_each do |item|
        output << item
      end
    end

    processor :process do |item, output|
      result = process_item(item)
      # Mark as processed AFTER success
      item.update!(status: 'completed', result: result)
      output << result
    end

    consumer :notify do |result|
      send_notification(result)
    end
  end
end
```

**Benefits:**
- Pipeline can be restarted safely
- Only unprocessed items are picked up
- Progress is tracked in the database

### Redis Queue Producer

```ruby
require 'redis'

class RedisQueuePipeline
  include Minigun::DSL

  def initialize
    @redis = Redis.new
  end

  pipeline do
    producer :queue_items do |output|
      loop do
        # BRPOPLPUSH: atomic move from pending to processing
        item = @redis.brpoplpush('pending_items', 'processing_items', timeout: 5)
        break unless item

        output << JSON.parse(item)
      end
    end

    processor :process do |item, output|
      result = process_item(item)

      # Remove from processing queue on success
      @redis.lrem('processing_items', 1, item.to_json)

      output << result
    end

    consumer :complete do |result|
      # Store result
      @redis.lpush('completed_items', result.to_json)
    end
  end
end

# Recovery: Move stuck items back to pending
def recover_stuck_items(redis, timeout: 300)
  redis.lrange('processing_items', 0, -1).each do |item|
    data = JSON.parse(item)
    if Time.now - Time.parse(data['started_at']) > timeout
      redis.lrem('processing_items', 1, item)
      redis.lpush('pending_items', item)
    end
  end
end
```

### File-Based Checkpointing

```ruby
class CheckpointedPipeline
  include Minigun::DSL

  CHECKPOINT_FILE = 'pipeline_checkpoint.json'

  def initialize
    @checkpoint = load_checkpoint
  end

  def load_checkpoint
    return { processed_ids: Set.new } unless File.exist?(CHECKPOINT_FILE)

    data = JSON.parse(File.read(CHECKPOINT_FILE))
    { processed_ids: Set.new(data['processed_ids']) }
  end

  def save_checkpoint
    File.write(CHECKPOINT_FILE, JSON.generate({
      processed_ids: @checkpoint[:processed_ids].to_a,
      updated_at: Time.now.iso8601
    }))
  end

  pipeline do
    producer :items do |output|
      all_items.each do |item|
        # Skip already processed items
        next if @checkpoint[:processed_ids].include?(item.id)

        output << item
      end
    end

    processor :process do |item, output|
      result = process_item(item)

      # Checkpoint after each item
      @checkpoint[:processed_ids].add(item.id)
      save_checkpoint

      output << result
    end
  end
end
```

## Pattern 3: External Orchestration

For true high availability, use external orchestration to manage pipeline execution.

### Kubernetes Job

```yaml
# pipeline-job.yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: data-pipeline
spec:
  backoffLimit: 3  # Retry failed jobs
  template:
    spec:
      restartPolicy: OnFailure
      containers:
      - name: pipeline
        image: myapp:latest
        command: ["ruby", "run_pipeline.rb"]
        resources:
          requests:
            memory: "512Mi"
            cpu: "500m"
```

### Kubernetes CronJob (Scheduled)

```yaml
# pipeline-cronjob.yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: hourly-pipeline
spec:
  schedule: "0 * * * *"  # Every hour
  jobTemplate:
    spec:
      backoffLimit: 3
      template:
        spec:
          restartPolicy: OnFailure
          containers:
          - name: pipeline
            image: myapp:latest
            command: ["ruby", "run_pipeline.rb"]
```

### Systemd Service with Restart

```ini
# /etc/systemd/system/minigun-pipeline.service
[Unit]
Description=Minigun Data Pipeline
After=network.target

[Service]
Type=simple
User=app
WorkingDirectory=/app
ExecStart=/usr/bin/ruby run_pipeline.rb
Restart=on-failure
RestartSec=30
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
```

### Sidekiq/Resque for Job Management

```ruby
# app/jobs/pipeline_job.rb
class PipelineJob
  include Sidekiq::Job

  sidekiq_options retry: 3, queue: 'pipelines'

  def perform(pipeline_name, options = {})
    pipeline_class = pipeline_name.constantize
    pipeline = pipeline_class.new(**options.symbolize_keys)
    pipeline.run
  end
end

# Enqueue
PipelineJob.perform_async('MyDataPipeline', { batch_size: 1000 })
```

## Pattern 4: Graceful Shutdown

Handle SIGTERM/SIGINT for clean shutdown:

```ruby
class GracefulPipeline
  include Minigun::DSL

  def initialize
    @shutdown_requested = false
    setup_signal_handlers
  end

  def setup_signal_handlers
    %w[INT TERM].each do |signal|
      Signal.trap(signal) do
        puts "Shutdown requested, finishing current items..."
        @shutdown_requested = true
      end
    end
  end

  pipeline do
    producer :items do |output|
      items_to_process.each do |item|
        break if @shutdown_requested

        output << item
      end

      puts "Producer finished (shutdown: #{@shutdown_requested})"
    end

    processor :process do |item, output|
      # Complete current item even during shutdown
      result = process_item(item)
      output << result
    end

    consumer :save do |result|
      save_result(result)
    end
  end
end
```

## Pattern 5: Monitoring and Alerting

### Structured Logging

```ruby
class MonitoredPipeline
  include Minigun::DSL

  pipeline do
    before_run do
      Minigun.logger.info({
        event: 'pipeline_started',
        pipeline: self.class.name,
        timestamp: Time.now.iso8601
      }.to_json)
    end

    after_run do
      stats = _minigun_task.root_pipeline.stats
      Minigun.logger.info({
        event: 'pipeline_completed',
        pipeline: self.class.name,
        items_processed: stats.total_items,
        duration_seconds: stats.duration,
        timestamp: Time.now.iso8601
      }.to_json)
    end

    # ... stages ...
  end
end
```

### Metrics Export

```ruby
require 'prometheus/client'

class MetricsPipeline
  include Minigun::DSL

  ITEMS_PROCESSED = Prometheus::Client::Counter.new(
    :pipeline_items_processed_total,
    docstring: 'Total items processed',
    labels: [:pipeline, :stage]
  )

  PROCESSING_DURATION = Prometheus::Client::Histogram.new(
    :pipeline_processing_duration_seconds,
    docstring: 'Processing duration per item',
    labels: [:pipeline, :stage]
  )

  pipeline do
    processor :process do |item, output|
      start = Time.now
      result = process_item(item)
      duration = Time.now - start

      ITEMS_PROCESSED.increment(labels: { pipeline: 'main', stage: 'process' })
      PROCESSING_DURATION.observe(duration, labels: { pipeline: 'main', stage: 'process' })

      output << result
    end
  end
end
```

## Anti-Patterns to Avoid

### Don't: Rely on In-Memory State

```ruby
# BAD: Progress lost on crash
class BadPipeline
  include Minigun::DSL

  def initialize
    @processed = []  # Lost on crash!
  end

  pipeline do
    consumer :process do |item|
      @processed << process_item(item)
    end
  end
end
```

### Don't: Assume Coordinator HA Exists

```ruby
# BAD: There's no automatic coordinator failover
# If coordinator crashes, job fails
in_cluster(coordinator_uri: 'druby://primary:9000') do
  # This won't magically failover to another coordinator
end
```

### Don't: Ignore Idempotency with At-Least-Once

```ruby
# BAD: Non-idempotent with at_least_once = duplicate side effects
in_cluster(delivery_mode: :at_least_once) do
  processor :charge_customer do |order, output|
    # DANGER: Customer may be charged multiple times!
    charge_credit_card(order.customer, order.amount)
    output << order
  end
end

# GOOD: Idempotent version
in_cluster(delivery_mode: :at_least_once) do
  processor :charge_customer do |order, output|
    # Check if already charged using idempotency key
    unless Payment.exists?(idempotency_key: order.id)
      charge_credit_card(order.customer, order.amount)
      Payment.create!(idempotency_key: order.id, order_id: order.id)
    end
    output << order
  end
end
```

## Summary

| Requirement | Solution |
|-------------|----------|
| Worker crashes shouldn't lose items | `restart_policy: :transient` for IPC forks |
| Network failures shouldn't lose items | `delivery_mode: :at_least_once` for clusters |
| Pipeline crashes shouldn't lose progress | Persistent input source (DB, Redis, files) |
| Automatic job restart | External orchestration (K8s, systemd, Sidekiq) |
| Zero data loss | Persistent queues + idempotent processors + checkpointing |

**The golden rule:** Minigun handles worker-level recovery. For job-level recovery, use persistent input sources and external orchestration.
