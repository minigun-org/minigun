# Converted Code - Original Publishers Using Minigun

This directory contains the original `PublisherBase` and `ElasticAtomicPublisher` classes converted to use the Minigun gem.

## What Was Added to Minigun

To support the conversion, we added **stage-specific hooks** to Minigun using **Option 2 + 3** (named hooks + inline proc hooks):

### 1. Named Hooks (Option 2)
```ruby
producer :generate_ids do
  # producer code
end

after :generate_ids do
  # Called after producer finishes
  cleanup_resources
end

before_fork :consume_ids do
  Mongoid.disconnect_clients
end

after_fork :consume_ids do
  Mongoid.reconnect_clients
end
```

### 2. Inline Proc Hooks (Option 3)
```ruby
producer :generate,
         before: -> { setup },
         after: -> { cleanup },
         before_fork: -> { disconnect_db },
         after_fork: -> { reconnect_db } do
  emit(items)
end
```

### 3. Hook Types
- `before(stage_name)` - Runs before stage executes
- `after(stage_name)` - Runs after stage completes
- `before_fork(stage_name)` - Runs before forking for this specific stage
- `after_fork(stage_name)` - Runs after forking (in child process) for this stage

### 4. Mixed with Pipeline-Level Hooks
```ruby
# Pipeline-level (run once)
before_run do
  @start_time = Time.now
end

# Stage-specific (run per stage)
after :generate_ids do
  puts "Generated #{@count} IDs"
end

after_run do
  puts "Total time: #{Time.now - @start_time}"
end
```

## Files

### `publisher_base.rb`
Converted base class demonstrating:
- Producer → Accumulator → Fork Consumer pattern
- Lifecycle hooks (`before_run`, `after_run`, `before_fork`, `after_fork`)
- Stage-specific hooks (`after :generate_ids`, `before_fork :consume_ids`)
- Subclass template methods (`before_job_start!`, `after_producer_finished!`, etc.)
- Configuration (`max_threads`, `max_processes`, `max_retries`)

**Original pattern:**
```ruby
def perform
  bootstrap!
  before_job_start!
  producer_thread = start_producer_thread
  accumulator_thread = start_accumulator_thread
  producer_thread.join
  accumulator_thread.join
  wait_all_consumer_processes
  after_job_finished!
end
```

**Minigun equivalent:**
```ruby
before_run do
  bootstrap!
  before_job_start!
end

producer :generate_ids do
  # Generate IDs
end

after :generate_ids do
  after_producer_finished!
end

fork_accumulate :consume_ids do |model, id|
  consume_object(model, id)
end

after_run do
  after_job_finished!
end
```

### `elastic_atomic_publisher.rb`
Subclass demonstrating:
- Inheritance of parent's stages and hooks
- Overriding `consume_object` method
- Custom model list
- Elasticsearch-specific logic (stubbed)

## Key Patterns

### 1. Copy-On-Write Fork Strategy
```ruby
fork_accumulate :consume_ids do |model, id|
  # Processes batches in forked processes
  # COW optimization for memory efficiency
end
```

### 2. Database Connection Management
```ruby
before_fork do
  disconnect_database!
end

after_fork do
  reconnect_database!
end
```

### 3. Resource Cleanup
```ruby
after :generate_ids do
  GC.start
  log_statistics
end
```

## Running the Example

```bash
ruby converted-code/elastic_atomic_publisher.rb
```

**Output:**
```
=== ElasticAtomicPublisher Example ===

[Bootstrap] Initializing...
ElasticAtomicPublisher started.
  job_start_at    2025-10-26 00:48:01 +0900
  ...

[Producer] Starting ID generation for 2 models
[Producer] Customer: Produced 1000 IDs
[Producer] Reservation: Produced 1000 IDs
[Producer] Done. 2000 object IDs produced.

[Elastic] Upserting Customer#customer_cf58038...
[Elastic] Upserting Customer#customer_540a4d2...
...

=== Final Stats ===
Produced: 2000 IDs
Consumed: 2000 items
```

## Tests

Stage-specific hooks are fully tested in `spec/unit/stage_hooks_spec.rb`:
- Named hooks execution order
- Inline proc hooks
- Fork-specific hooks
- Mixed pipeline and stage hooks
- Multiple hooks on same stage

Run tests:
```bash
bundle exec rspec spec/unit/stage_hooks_spec.rb
```

## Implementation Details

### Inheritance Support
Subclasses automatically inherit parent's task (including all stages and hooks) via `inherited` callback:

```ruby
def base.inherited(subclass)
  parent_task = self._minigun_task
  new_task = Minigun::Task.new
  new_task.instance_variable_set(:@config, parent_task.config.dup)
  new_task.instance_variable_set(:@implicit_pipeline, parent_task.implicit_pipeline)
  subclass.instance_variable_set(:@_minigun_task, new_task)
end
```

### Hook Storage
```ruby
# Pipeline-level hooks (run once per pipeline)
@hooks = {
  before_run: [],
  after_run: [],
  before_fork: [],
  after_fork: []
}

# Stage-specific hooks (run per stage execution)
@stage_hooks = {
  before: { stage_name => [blocks] },
  after: { stage_name => [blocks] },
  before_fork: { stage_name => [blocks] },
  after_fork: { stage_name => [blocks] }
}
```

### Hook Execution
Hooks are executed at the appropriate points in the pipeline lifecycle:
- `before` hooks: Before stage block execution
- `after` hooks: After stage block execution
- `before_fork` hooks: Before forking child process (parent process)
- `after_fork` hooks: After forking (in child process)

## Comparison with Original

| Original PublisherBase | Minigun Equivalent |
|---|---|
| `before_job_start!` | `before_run do...end` |
| `after_producer_finished!` | `after :producer_name do...end` |
| `before_consumer_fork!` | `before_fork :consumer_name do...end` or `before_fork do...end` |
| `after_consumer_fork!` | `after_fork :consumer_name do...end` or `after_fork do...end` |
| `after_job_finished!` | `after_run do...end` |
| `start_producer_thread` | `producer :name do...end` |
| `start_accumulator_thread` | Automatic (part of pipeline) |
| `fork_consumer` | `fork_accumulate :name do...end` |
| `max_processes` | `max_processes N` |
| `max_threads` | `max_threads N` |
| `max_retries` | `max_retries N` |

## Benefits of Minigun Conversion

1. **Cleaner DSL**: Declarative stage definitions vs. imperative thread management
2. **Less Boilerplate**: No need to manually manage threads, queues, PIDs
3. **Built-in Routing**: DAG-based stage routing with `to:` option
4. **Flexible Hooks**: Both pipeline-level and stage-specific hooks
5. **Strategy Pattern**: Easy to switch between threaded/forked/IPC/ractor execution
6. **Thread Safety**: Built-in atomic counters and mutex handling
7. **Testing**: Easier to test individual stages in isolation
8. **Reusability**: Stages can be composed and reused across pipelines

## Future Enhancements

Potential additions based on original PublisherBase features:
- Retry logic with exponential backoff (already configured via `max_retries`)
- Progress tracking and reporting
- Error handling and recovery strategies
- Time-based batching (currently size-based only)
- Metrics and instrumentation
- Dynamic configuration per-instance (currently class-level)

