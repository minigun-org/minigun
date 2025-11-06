# Comparison: When to Use Minigun

Minigun is designed for specific use cases. This guide helps you decide if it's the right tool and how it compares to alternatives like Sidekiq.

## Quick Decision Tree

```
Do you need persistent job queues?
├─ Yes → Use Sidekiq, Resque, or Solid Queue
└─ No → Continue...

Do you need distributed workers across multiple machines?
├─ Yes → Use Sidekiq, Resque, or a distributed queue
└─ No → Continue...

Do you need job scheduling (cron-like features)?
├─ Yes → Use Sidekiq Enterprise, Clockwork, or Whenever
└─ No → Continue...

Do you have multi-stage data processing workflows?
├─ Yes → Minigun is a great fit! ✓
└─ No → Continue...

Do you need to process data in-memory with parallelism?
├─ Yes → Minigun is a great fit! ✓
└─ No → Consider alternatives
```

## Minigun vs Sidekiq: Quick Summary

| Feature | Minigun | Sidekiq |
|---------|---------|---------|
| **Purpose** | In-memory data pipelines | Persistent background jobs |
| **Storage** | Memory only | Redis (persistent) |
| **Stages** | Native multi-stage | Single-stage (manual chaining) |
| **Distribution** | Single process tree | Multi-machine |
| **Dependencies** | None | Redis |
| **Parallelism** | Threads + Processes | Threads only |
| **Scheduling** | None | Yes (Enterprise) |
| **Setup Time** | Instant | 5-10 minutes |
| **Cost** | Free (OSS) | $0-$799/month |

## Minigun's Sweet Spot

### ✅ Use Minigun When:

#### 1. In-Memory Data Processing

**Perfect for:**
```ruby
# ETL pipeline that runs to completion
class DataMigration
  include Minigun::DSL

  pipeline do
    producer :extract { LegacyDB.find_each { |r| emit(r) } }
    processor :transform, threads: 10 { |r, output| output << transform(r) }
    consumer :load { |r| NewDB.insert(r) }
  end
end
```

#### 2. Multi-Stage Workflows

**Perfect for:**
```ruby
# Complex pipeline with multiple transformation steps
pipeline do
  producer :fetch { fetch_data }
  processor :clean, threads: 5 { |data, output| output << clean(data) }
  processor :validate { |data, output| output << validate(data) }
  processor :enrich, threads: 20 { |data, output| output << enrich(data) }
  accumulator :batch, max_size: 100 { |batch, output| output << batch }
  consumer :save, threads: 4 { |batch| save_batch(batch) }
end
```

#### 3. Batch Processing

**Perfect for:**
```ruby
# Process large datasets efficiently
class BatchJob
  include Minigun::DSL

  pipeline do
    producer :stream { Record.find_each(batch_size: 1000) { |r| emit(r) } }
    processor :process, execution: :cow_fork, max: 8 { |r| process(r) }
    accumulator :batch, max_size: 500 { |batch| emit(batch) }
    consumer :save { |batch| bulk_insert(batch) }
  end
end
```

#### 4. Web Scraping & Crawling

**Perfect for:**
```ruby
# Parallel web scraping
pipeline do
  producer :urls { urls.each { |url| emit(url) } }
  processor :fetch, threads: 20 { |url, output| output << HTTP.get(url) }
  processor :parse, threads: 5 { |html, output| output << parse(html) }
  consumer :save { |data| save_to_db(data) }
end
```

#### 5. Data Enrichment

**Perfect for:**
```ruby
# Enrich data from multiple sources
pipeline do
  producer :users { User.find_each { |u| emit(u) } }

  # Fan-out to multiple APIs
  processor :split, to: [:api_a, :api_b, :api_c] { |user, output| output << user }

  processor :api_a, to: :merge, threads: 20 { |user| fetch_api_a(user) }
  processor :api_b, to: :merge, threads: 20 { |user| fetch_api_b(user) }
  processor :api_c, to: :merge, threads: 20 { |user| fetch_api_c(user) }

  # Fan-in to merge results
  processor :merge { |result| combine_and_save(result) }
end
```

### ❌ Don't Use Minigun When:

#### 1. You Need Persistence

**Use Sidekiq instead:**
```ruby
# Jobs survive server restarts
class UserEmailJob < ApplicationJob
  queue_as :default

  def perform(user_id)
    user = User.find(user_id)
    UserMailer.welcome_email(user).deliver_now
  end
end
```

**Why Sidekiq?**
- Jobs stored in Redis (survive crashes)
- Can retry failed jobs days later
- Workers can restart without losing jobs

#### 2. You Need Distribution

**Use Sidekiq/Resque instead:**
```ruby
# Workers across multiple machines
# Machine 1: Web server enqueues
UserEmailJob.perform_later(user.id)

# Machine 2-5: Workers process
# Each machine runs: bundle exec sidekiq
```

**Why Sidekiq?**
- Redis acts as central queue
- Workers on any machine
- Scale horizontally

#### 3. You Need Scheduling

**Use Sidekiq Enterprise or Clockwork:**
```ruby
# Scheduled jobs
class DailyReportJob < ApplicationJob
  def perform
    generate_and_send_report
  end
end

# config/schedule.rb
every 1.day, at: '6:00 am' do
  DailyReportJob.perform_later
end
```

**Why Sidekiq Enterprise?**
- Cron-like scheduling
- Recurring jobs
- Calendar-based execution

#### 4. Jobs Run for Hours/Days

**Use a persistent queue:**
```ruby
# Very long-running job
class BigDataProcessingJob < ApplicationJob
  def perform
    # Takes 8 hours
    process_terabytes_of_data
  end
end
```

**Why persistent queue?**
- If server restarts, job resumes
- Can monitor progress
- Retry on failure

## Core Differences: Minigun vs Sidekiq

### 1. Persistence

**Sidekiq:**
```ruby
# Jobs stored in Redis
class WelcomeEmailJob < ApplicationJob
  def perform(user_id)
    UserMailer.welcome_email(user_id).deliver
  end
end

WelcomeEmailJob.perform_later(user_id)

# If server crashes:
# - Job survives in Redis
# - Worker picks it up when restarted
# - No data loss
```

**Minigun:**
```ruby
# Runs in memory
class EmailPipeline
  include Minigun::DSL

  pipeline do
    producer :users { User.find_each { |u| emit(u) } }
    processor :generate { |user, output| output << generate_email(user) }
    consumer :send { |email| send_email(email) }
  end
end

EmailPipeline.new.run

# If server crashes:
# - Pipeline stops
# - In-flight items lost
# - Must restart from beginning
```

**Winner:** Sidekiq for jobs that must survive crashes.

### 2. Multi-Stage Processing

**Minigun:**
```ruby
# Natural multi-stage pipeline
pipeline do
  producer :extract { LegacyDB.find_each { |r| emit(r) } }
  processor :clean, threads: 10 { |r, output| output << clean(r) }
  processor :validate { |r, output| output << validate(r) }
  processor :enrich, threads: 20 { |r, output| output << enrich(r) }
  accumulator :batch, max_size: 500 { |batch| emit(batch) }
  consumer :load, threads: 4 { |batch| insert_many(batch) }
end

# All stages defined in one place
# Data flows automatically
# Can monitor entire pipeline
```

**Sidekiq:**
```ruby
# Must chain jobs manually
class ExtractJob < ApplicationJob
  def perform
    LegacyDB.find_each do |record|
      CleanJob.perform_later(record)
    end
  end
end

class CleanJob < ApplicationJob
  def perform(record)
    cleaned = clean(record)
    ValidateJob.perform_later(cleaned)
  end
end

class ValidateJob < ApplicationJob
  def perform(record)
    validated = validate(record)
    EnrichJob.perform_later(validated)
  end
end

# ... more jobs ...

# Jobs are separate
# Hard to see full workflow
# Must manage state externally
```

**Winner:** Minigun for multi-stage workflows.

### 3. Parallelism Models

**Minigun:**
```ruby
pipeline do
  # Threads for I/O-bound work
  processor :fetch_api, threads: 50 do |id, output|
    output << HTTP.get("https://api.example.com/#{id}")
  end

  # COW forks for CPU-bound work with large data
  processor :process_image, execution: :cow_fork, max: 8 do |image, output|
    output << @model.predict(image)  # Model shared via COW
  end

  # IPC forks for long-running workers
  processor :ml_inference, execution: :ipc_fork, max: 4 do |data, output|
    @model ||= load_expensive_model  # Loaded once per worker
    output << @model.predict(data)
  end
end
```

**Sidekiq:**
```ruby
# Threads only (subject to GVL)
class MyJob < ApplicationJob
  sidekiq_options concurrency: 25  # Max threads

  def perform(id)
    # CPU-intensive work limited by GVL
    # Can't use fork (loses Redis connection)
    expensive_computation(id)
  end
end
```

**Winner:** Minigun for CPU-intensive work or mixed workloads.

### 4. Distribution

**Sidekiq:**
```ruby
# Machine 1 (Web server)
UserEmailJob.perform_later(user.id)

# Machine 2-10 (Workers)
# Each runs: bundle exec sidekiq

# Jobs distributed automatically via Redis
# Scale horizontally by adding machines
```

**Minigun:**
```ruby
# Single machine only
# All stages run within one process tree
# Cannot distribute across machines
```

**Winner:** Sidekiq for distributed systems.

### 5. Observability

**Minigun:**
```ruby
require 'minigun/hud'

# Real-time terminal UI
Minigun::HUD.run_with_hud(MyPipeline)

# Shows:
# - Live throughput per stage
# - Latency percentiles
# - Bottleneck detection
# - Animated data flow
# - Per-stage statistics
```

**Sidekiq:**
```ruby
# Web UI (requires rack)
require 'sidekiq/web'
mount Sidekiq::Web => '/sidekiq'

# Shows:
# - Queue depths
# - Job history
# - Failed jobs
# - Worker status
# - Requires browser
```

**Winner:** Tie - Different styles for different needs.

## Use Case Examples

### ✅ Good Fit: ETL Pipeline

**Scenario:** Migrate 1M records from legacy DB to new system.

**Why Minigun:**
- Runs once, doesn't need persistence
- Multi-stage pipeline (extract → transform → load)
- Needs parallelism (threads for I/O, forks for CPU)
- Can monitor progress with HUD
- No infrastructure needed

```ruby
class DataMigration
  include Minigun::DSL

  pipeline do
    producer :extract { LegacyDB.find_each { |r| emit(r) } }
    processor :clean, threads: 10 { |r, output| output << clean(r) }
    processor :transform, execution: :cow_fork, max: 8 { |r| transform(r) }
    accumulator :batch, max_size: 500 { |batch| emit(batch) }
    consumer :load, threads: 4 { |batch| NewDB.insert_many(batch) }
  end
end

Minigun::HUD.run_with_hud(DataMigration)
```

### ❌ Bad Fit: Background Jobs

**Scenario:** Send welcome email when user signs up.

**Why Sidekiq:**
- Needs persistence (what if server restarts?)
- Single-stage job (just send email)
- Distributed workers (multiple app servers)
- Want retries over days if email fails

```ruby
# Use Sidekiq instead
class WelcomeEmailJob < ApplicationJob
  retry_on Net::SMTPError, wait: :exponentially_longer

  def perform(user_id)
    user = User.find(user_id)
    UserMailer.welcome_email(user).deliver_now
  end
end

# Survives restarts, retries, distributed
WelcomeEmailJob.perform_later(user.id)
```

### ✅ Good Fit: Web Scraper

**Scenario:** Scrape 10,000 product pages nightly.

**Why Minigun:**
- Runs to completion (doesn't need persistence)
- Multi-stage (fetch → parse → extract → save)
- High parallelism (20 threads fetching)
- Monitor with HUD
- No infrastructure

```ruby
class ProductScraper
  include Minigun::DSL

  pipeline do
    producer :urls { Product.pluck(:url).each { |url| emit(url) } }
    processor :fetch, threads: 20 { |url, output| output << HTTP.get(url) }
    processor :parse, threads: 5 { |html, output| output << parse(html) }
    consumer :save { |data| Product.update_data(data) }
  end
end
```

## Hybrid Approach

Use both Minigun and Sidekiq together for the best of both worlds:

```ruby
# Sidekiq handles scheduling and persistence
class ProcessDataJob < ApplicationJob
  queue_as :data_processing

  def perform(dataset_id)
    dataset = Dataset.find(dataset_id)

    # Minigun handles complex multi-stage processing
    class DataPipeline
      include Minigun::DSL

      pipeline do
        producer :extract { dataset.records.find_each { |r| emit(r) } }
        processor :transform, threads: 10 { |r, output| output << transform(r) }
        processor :enrich, threads: 20 { |r, output| output << enrich(r) }
        accumulator :batch, max_size: 500 { |batch| emit(batch) }
        consumer :load, threads: 4 { |batch| bulk_insert(batch) }
      end
    end

    DataPipeline.new.run
  end
end

# Schedule with Sidekiq
ProcessDataJob.set(wait: 1.hour).perform_later(dataset.id)
```

**Benefits:**
- Sidekiq: Scheduling, persistence, distribution
- Minigun: Complex pipelines, parallelism, monitoring
- Use right tool for each part

## Comparison Matrix

| Feature | Minigun | Sidekiq | Resque | Solid Queue |
|---------|---------|---------|--------|-------------|
| **In-Memory** | ✅ Yes | ❌ No | ❌ No | ❌ No |
| **Persistent** | ❌ No | ✅ Redis | ✅ Redis | ✅ DB |
| **Multi-Stage** | ✅ Native | ❌ Manual | ❌ Manual | ❌ Manual |
| **Distributed** | ❌ No | ✅ Yes | ✅ Yes | ✅ Yes |
| **Threads** | ✅ Yes | ✅ Yes | ❌ Processes | ✅ Yes |
| **Processes** | ✅ COW/IPC | ❌ No | ✅ Yes | ❌ No |
| **Scheduling** | ❌ No | ✅ Enterprise | ❌ Plugins | ❌ No |
| **Dependencies** | None | Redis | Redis | Database |
| **Setup Time** | Instant | Minutes | Minutes | Minutes |

## Cost Comparison

### Sidekiq

**Free (OSS):**
- Basic background jobs
- Unlimited workers
- Unlimited queues
- Web UI
- Retries

**Pro ($179/month):**
- Reliability features
- Better performance
- Batches
- Rate limiting

**Enterprise ($799/month):**
- Periodic jobs (cron)
- Rolling restarts
- Leader election
- Expiring jobs

**Infrastructure:**
- Redis instance ($10-100/month)
- Additional servers for workers

### Minigun

**Free (OSS):**
- Everything included
- No limits
- No infrastructure costs
- No external dependencies

**Cost:** $0

## Key Takeaways

### Choose Minigun for:
- ✅ In-memory data processing
- ✅ Multi-stage pipelines
- ✅ Batch processing
- ✅ ETL workflows
- ✅ One-off data transformations
- ✅ Development and testing

### Choose Sidekiq/Resque for:
- ✅ Persistent background jobs
- ✅ Distributed processing
- ✅ Job scheduling
- ✅ Long-running jobs
- ✅ Retry over days/weeks
- ✅ Production web apps

### Hybrid Approach:
- Use Sidekiq to schedule and persist jobs
- Use Minigun inside jobs for complex processing

## Next Steps

- [Guides: Introduction](guides/01_introduction.md) - Learn Minigun
- [Recipes](recipes/) - See Minigun in action

---

**Still unsure?** Check out the [Recipes](recipes/) to see if your use case matches.
