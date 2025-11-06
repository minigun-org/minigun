# Deployment Guide

How to deploy Minigun pipelines in production environments.

## Key Principle: Minigun is a Task Runner

**Important:** Minigun is designed to run as a **task runner**, not as part of your web server request/response cycle.

### ❌ Don't Do This

```ruby
# DON'T run Minigun in controllers!
class DataPipeline
  include Minigun::DSL

  pipeline do
    producer :fetch { ... }
    processor :transform, execution: :cow_fork, max: 8 { ... }
    consumer :save { ... }
  end
end

class UsersController < ApplicationController
  def process_data
    DataPipeline.new.run  # ❌ Blocks request, forks during request!

    render json: { status: 'done' }
  end
end
```

**Why this is bad:**
- Blocks HTTP requests (timeouts)
- Forks inside web processes (memory bloat)
- Ties up web workers
- Can crash web server on fork
- No retry/monitoring

### ✅ Do This Instead

Run Minigun pipelines as separate tasks:

```ruby
# Option 1: Scheduled task
# config/schedule.rb (with "whenever" gem)
every 1.hour do
  rake "data:process"
end

# lib/tasks/data.rake
namespace :data do
  task process: :environment do
    DataPipeline.new.run
  end
end

# Option 2: Background job
class ProcessDataJob < ApplicationJob
  def perform(dataset_id)
    DataPipeline.new(dataset_id).run
  end
end

# In controller - enqueue job, don't run directly
class UsersController < ApplicationController
  def process_data
    ProcessDataJob.perform_later(params[:dataset_id])
    render json: { status: 'queued' }
  end
end
```

## Deployment Architectures

### 1. Scheduled Tasks (Cron)

**Best for:** Recurring data processing, ETL, batch jobs

```bash
# crontab
0 */4 * * * cd /app && bundle exec rake data:sync
0 2 * * * cd /app && bundle exec ruby scripts/daily_report.rb
```

**Using Whenever gem:**

```ruby
# config/schedule.rb
set :output, 'log/cron.log'

every 1.day, at: '2:00 am' do
  rake "reports:daily"
end

every 4.hours do
  runner "DataSyncPipeline.new.run"
end
```

### 2. Task Orchestration Platforms

**Best for:** Complex workflows, dependencies, monitoring

#### Apache Airflow

```python
# dags/minigun_pipeline.py
from airflow import DAG
from airflow.operators.bash import BashOperator
from datetime import datetime, timedelta

default_args = {
    'owner': 'data-team',
    'depends_on_past': False,
    'retries': 2,
    'retry_delay': timedelta(minutes=5)
}

dag = DAG(
    'data_processing',
    default_args=default_args,
    schedule_interval='@hourly',
    catchup=False
)

process_task = BashOperator(
    task_id='run_minigun_pipeline',
    bash_command='cd /app && bundle exec ruby scripts/process_data.rb',
    dag=dag
)
```

**Resources needed:**
- One worker per pipeline
- CPU cores ≥ `max_processes` (for fork execution)
- Memory: Base Ruby + (forked processes × process memory)

#### Luigi (Spotify)

```python
# tasks/minigun_task.py
import luigi
import subprocess

class DataProcessingTask(luigi.Task):
    date = luigi.DateParameter()

    def run(self):
        subprocess.run([
            'bundle', 'exec', 'ruby',
            'scripts/process_data.rb',
            str(self.date)
        ], check=True)

    def output(self):
        return luigi.LocalTarget(f'data/processed/{self.date}.json')
```

#### Prefect

```python
# flows/minigun_flow.py
from prefect import flow, task
import subprocess

@task(retries=3)
def run_minigun_pipeline(dataset_id: str):
    result = subprocess.run(
        ['bundle', 'exec', 'ruby', 'scripts/pipeline.rb', dataset_id],
        capture_output=True,
        text=True
    )
    return result.stdout

@flow
def data_processing_flow(dataset_ids: list[str]):
    for dataset_id in dataset_ids:
        run_minigun_pipeline(dataset_id)
```

#### Dagster

```python
# pipelines/minigun_job.py
from dagster import job, op
import subprocess

@op
def run_minigun_pipeline():
    subprocess.run(
        ['bundle', 'exec', 'ruby', 'scripts/pipeline.rb'],
        check=True
    )

@job
def data_processing_job():
    run_minigun_pipeline()
```

### 3. Kubernetes Jobs

**Best for:** Cloud-native deployments, auto-scaling

```yaml
# k8s/minigun-job.yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: data-processing
spec:
  template:
    spec:
      containers:
      - name: minigun
        image: myapp:latest
        command: ["bundle", "exec", "ruby"]
        args: ["scripts/process_data.rb"]
        resources:
          requests:
            cpu: "4"      # Match your max_processes
            memory: "8Gi"
          limits:
            cpu: "8"
            memory: "16Gi"
      restartPolicy: OnFailure
```

**CronJob for scheduling:**

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: hourly-data-sync
spec:
  schedule: "0 * * * *"
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: minigun
            image: myapp:latest
            command: ["bundle", "exec", "rake", "data:sync"]
            resources:
              requests:
                cpu: "8"    # For 8 fork processes
                memory: "16Gi"
```

### 4. Standalone Worker Processes

**Best for:** Long-running pipelines, continuous processing

```ruby
# bin/worker
#!/usr/bin/env ruby
require_relative '../config/environment'

loop do
  begin
    StreamProcessor.new.run
  rescue => e
    logger.error("Pipeline failed: #{e.message}")
    sleep 10  # Back off before retry
  end
end
```

**Systemd service:**

```ini
# /etc/systemd/system/minigun-worker.service
[Unit]
Description=Minigun Worker
After=network.target

[Service]
Type=simple
User=deploy
WorkingDirectory=/app
ExecStart=/app/bin/worker
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
```

**Start service:**
```bash
sudo systemctl enable minigun-worker
sudo systemctl start minigun-worker
sudo journalctl -u minigun-worker -f
```

## Resource Requirements

### CPU Cores

**For Fork Execution:**

```ruby
execution :cow_fork, max: 8
# Needs: 8+ CPU cores for true parallelism

execution :ipc_fork, max: 4
# Needs: 4+ CPU cores
```

**Rule of thumb:**
- **COW/IPC Fork:** CPU cores ≥ `max` parameter
- **Threads:** 1-2 cores sufficient (I/O-bound)
- **Mixed:** Sum of max processes across all fork stages

**Example:**

```ruby
pipeline do
  processor :transform, execution: :cow_fork, max: 4
  processor :classify, execution: :ipc_fork, max: 2
  processor :enrich, threads: 20
end

# CPU needs: 4 + 2 = 6 cores minimum
# Threads don't need additional cores (I/O-bound)
```

### Memory

**Calculation:**

```
Total Memory = Base Process + (Forked Processes × Process Size)
```

**Example:**

```ruby
# Base Rails app: 500MB
# Each forked process: ~500MB (COW shared, but assume worst case)
# max: 8 processes

# Total: 500MB + (8 × 500MB) = 4.5GB
# Recommendation: 8GB (buffer for peaks)
```

**For IPC Fork:**
- Each worker is independent: `max × process_size`
- Less memory sharing than COW

**For Threads:**
- Single process: Base memory only
- Threads share memory: ~Base + thread overhead

### Storage

- **Logs:** Plan for verbose logging (HUD, stats)
- **Temp files:** Some pipelines may use /tmp
- **Results:** Consider output size

## Environment-Specific Configs

### Development

```ruby
# config/environments/development.rb
config.minigun.execution = :inline  # Easy debugging
config.minigun.max_threads = 2      # Low resource usage
```

### Testing

```ruby
# config/environments/test.rb
config.minigun.execution = :inline  # Deterministic
config.minigun.stats_enabled = false  # Faster tests
```

### Production

```ruby
# config/environments/production.rb
config.minigun.execution = :thread  # Default strategy
config.minigun.max_threads = 50
config.minigun.max_processes = ENV.fetch('MINIGUN_MAX_FORKS', 8).to_i
```

## Monitoring

### Logging

```ruby
class MonitoredPipeline
  include Minigun::DSL

  before_run do
    logger.info("Pipeline starting: #{self.class.name}")
    @start_time = Time.now
  end

  after_run do
    duration = Time.now - @start_time
    logger.info("Pipeline completed in #{duration}s")
  end

  pipeline do
    # ...
  end

  private

  def logger
    @logger ||= Logger.new('log/pipelines.log')
  end
end
```

### Metrics

```ruby
after_run do
  stats = root_pipeline.stats

  # Send to metrics service
  Datadog::Statsd.new.gauge('pipeline.duration', stats.duration)
  Datadog::Statsd.new.gauge('pipeline.throughput', stats.throughput)
  Datadog::Statsd.new.gauge('pipeline.items_processed', stats.total_produced)
end
```

### Alerting

```ruby
after_run do |result|
  if result[:status] == :failed
    PagerDuty.trigger(
      service_key: ENV['PAGERDUTY_KEY'],
      description: "Pipeline failed: #{self.class.name}",
      details: result[:error]
    )
  end
end
```

## Error Handling

### Graceful Shutdown

```ruby
# Respond to SIGTERM
Signal.trap('TERM') do
  puts "Shutting down gracefully..."
  @pipeline.stop if @pipeline
  exit
end

@pipeline = DataPipeline.new
@pipeline.run
```

### Retries

```ruby
# With exponential backoff
retries = 0
max_retries = 3

begin
  DataPipeline.new.run
rescue => e
  retries += 1
  if retries <= max_retries
    sleep_time = 2 ** retries
    logger.error("Pipeline failed (attempt #{retries}/#{max_retries}): #{e.message}")
    sleep sleep_time
    retry
  else
    logger.fatal("Pipeline failed after #{max_retries} attempts")
    raise
  end
end
```

### Dead Letter Queue

```ruby
class ResilientPipeline
  include Minigun::DSL

  def initialize
    @failed_items = []
  end

  pipeline do
    processor :process do |item, output|
      begin
        result = risky_operation(item)
        output << result
      rescue => e
        @failed_items << { item: item, error: e.message, timestamp: Time.now }
        logger.error("Item failed: #{item.inspect}")
      end
    end
  end

  after_run do
    unless @failed_items.empty?
      File.write(
        "failed_items_#{Time.now.to_i}.json",
        @failed_items.to_json
      )
    end
  end
end
```

## Platform-Specific Notes

### Heroku

```ruby
# Procfile
worker: bundle exec ruby scripts/pipeline_worker.rb
```

**Scheduler add-on:**
```bash
heroku addons:create scheduler:standard
# Configure via dashboard: 0 * * * * bundle exec rake data:sync
```

**Dynos:** Use Performance-M or larger for fork execution.

### AWS

**ECS Task:**
```json
{
  "family": "minigun-task",
  "containerDefinitions": [{
    "name": "minigun",
    "image": "myapp:latest",
    "memory": 8192,
    "cpu": 4096,
    "command": ["bundle", "exec", "ruby", "scripts/pipeline.rb"]
  }]
}
```

**Lambda:** ❌ Not recommended (15 min timeout, no fork support)

### Google Cloud

**Cloud Run Jobs:**
```yaml
apiVersion: run.googleapis.com/v1
kind: Job
metadata:
  name: minigun-pipeline
spec:
  template:
    spec:
      containers:
      - image: gcr.io/project/app:latest
        resources:
          limits:
            memory: 16Gi
            cpu: '8'
```

## Best Practices

### 1. Separate from Web Processes

```bash
# ✅ Good: Separate processes
web: bundle exec puma
worker: bundle exec rake data:process

# ❌ Bad: Mixed
web: bundle exec puma & bundle exec rake data:process
```

### 2. Match CPU to max_processes

```ruby
# 8-core machine
execution :cow_fork, max: 8  # ✅ Fully utilized

# 4-core machine
execution :cow_fork, max: 8  # ❌ Oversubscribed, slower

# 16-core machine
execution :cow_fork, max: 8  # ✅ Room for other processes
```

### 3. Monitor Resource Usage

```bash
# Check CPU cores
nproc

# Monitor during pipeline run
top -p $(pgrep -f ruby)
```

### 4. Test at Scale

```ruby
# Load test before production
pipeline = DataPipeline.new
benchmark = Benchmark.measure do
  pipeline.run
end

puts "Duration: #{benchmark.real}s"
puts "CPU: #{benchmark.total}s"
puts "Memory: #{memory_usage}MB"
```

## Troubleshooting

### Pipeline Hangs

**Check:** Deadlocks, infinite producers

```ruby
# Add timeout
Timeout.timeout(3600) do  # 1 hour
  DataPipeline.new.run
end
```

### Out of Memory

**Check:** Too many forks, memory leaks

```ruby
# Reduce max processes
execution :cow_fork, max: 4  # Was 16

# Add GC hints
processor :heavy, execution: :cow_fork, max: 4 do |item, output|
  result = process(item)
  GC.start if rand < 0.1  # Occasional GC
  output << result
end
```

### Fork Errors

**Check:** Platform doesn't support fork (Windows, JRuby)

```ruby
# Fallback to threads
if Minigun::Platform.fork_supported?
  execution :cow_fork, max: 8
else
  execution :thread, max: 10
end
```

## Summary

✅ **Do:**
- Run as separate tasks/jobs/workers
- Match CPU cores to max_processes
- Monitor resource usage
- Plan for retries and errors
- Use orchestration platforms for complex workflows

❌ **Don't:**
- Run in web controllers
- Fork inside web processes
- Oversubscribe CPU cores
- Ignore resource limits
- Skip monitoring

## See Also

- [Execution Strategies](06_execution_strategies.md) - Choosing the right strategy
- [Performance Tuning](11_performance_tuning.md) - Optimization
- [Comparison: When to Use](../comparison.md) - vs Sidekiq
