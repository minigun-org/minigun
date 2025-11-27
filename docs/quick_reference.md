# Minigun Quick Reference

Quick lookup for common Minigun patterns, API, and architecture.

## Stage Types

| Type | Run Mode | Input | Output | Executor | Example |
|------|----------|-------|--------|----------|---------|
| **Producer** | `:autonomous` | ✗ | ✓ | None | `producer :gen do \|output\|` |
| **Processor** | `:streaming` | ✓ | ✓ | Thread/Fork | `processor :xform do \|x, output\|` |
| **Consumer** | `:streaming` | ✓ | ✗ | Thread/Fork | `consumer :save do \|x\|` |
| **Accumulator** | `:streaming` | ✓ | ✓ | Thread/Fork | Batches N items before emit |
| **Router** | `:streaming` | ✓ | ✓ | None | Auto-inserted for fan-out |
| **Pipeline** | `:composite` | ✓ | ✓ | Special | Wraps nested pipeline |

## Execution Strategies

```
Thread Pool (:thread)          COW Fork (:cow_fork)       IPC Fork (:ipc_fork)
└─ Concurrency: Threads       └─ Concurrency: Processes  └─ Concurrency: Processes
   Shared memory                 Copy-On-Write memory       IPC pipes
   GVL limited                   No GVL                     Data serialized
   Best: I/O-bound               Best: CPU + large data     Best: CPU long-running
```

## Common Patterns

### Simple ETL
```ruby
producer :extract do |output|
  data.each { |item| output << item }
end

processor :transform do |item, output|
  output << transform(item)
end

consumer :load do |item|
  database.insert(item)
end
```

### Parallel Processing
```ruby
producer :source do |output|
  data.each { |item| output << item }
end

processor :heavy, threads: 8 do |item, output|
  output << expensive_operation(item)
end

consumer :store do |item|
  cache.set(item)
end
```

### Fan-Out (Broadcasting)
```ruby
producer :source, to: [:branch_a, :branch_b] do |output|
  data.each { |item| output << item }
end

processor :branch_a do |item, output|
  output << path_a(item)
end

processor :branch_b do |item, output|
  output << path_b(item)
end
```

### Batching
```ruby
producer :source do |output|
  items.each { |item| output << item }
end

accumulator :batch, max_size: 100 do |batch, output|
  output << batch
end

consumer :process do |batch|
  process_batch(batch)
end
```

## DSL Methods

### Pipeline Methods
```ruby
pipeline do
  # Stage definitions
end

# Named pipelines
pipeline :my_pipeline do
  # Stage definitions
end
```

### Stage Definition
```ruby
# Producer (generates data)
producer :name, to: :next_stage do |output|
  items.each { |item| output << item }
end

# Processor (transforms data)
processor :name, threads: 5 do |item, output|
  output << transform(item)
end

# Consumer (final processing)
consumer :name, from: :prev_stage do |item|
  save(item)
end

# Accumulator (batching)
accumulator :name, max_size: 100 do |batch, output|
  output << batch
end
```

### Execution Contexts
```ruby
# Thread pool
thread_pool 10 do
  processor :a do |item, output|
    # Runs with 10 threads
  end
end

# IPC fork
ipc_fork 4 do
  processor :b do |item, output|
    # Runs with 4 worker processes
  end
end

# COW fork
cow_fork 2 do
  processor :c do |item, output|
    # Forks 2 processes per item
  end
end
```

### Routing
```ruby
# Explicit routing
producer :a, to: :b do |output|
  # Routes to stage :b
end

# Multiple targets (fan-out)
producer :a, to: [:b, :c] do |output|
  # Broadcasts to both :b and :c
end

# Multiple sources (fan-in)
consumer :c, from: [:a, :b] do |item|
  # Receives from both :a and :b
end

# Dynamic routing
processor :router do |item, output|
  if item.urgent?
    output.to(:high_priority) << item
  else
    output.to(:normal) << item
  end
end
```

### Hooks
```ruby
# Pipeline-level hooks
before_run do
  setup_resources
end

after_run do
  cleanup_resources
end

before_fork do
  disconnect_db
end

after_fork do
  reconnect_db
end

# Stage-specific hooks
before :my_stage do
  stage_setup
end

after :my_stage do
  stage_cleanup
end
```

## Key Classes

### Pipeline
```ruby
pipeline = Minigun::Pipeline.new(name, task, parent_pipeline, config)
pipeline.add_stage(type, name, options, &block)
pipeline.run(context, job_id: nil)
pipeline.find_stage(name_or_obj)
pipeline.reroute_stage(from_stage, to: target)
```

### Stage
```ruby
stage.name           # Stage name
stage.run_mode       # :autonomous, :streaming, :composite
stage.execute(...)   # Process items
stage.queue_size     # Configured queue size
```

### Stats
```ruby
stats = pipeline.stats

# Per-stage metrics
stage_stats = stats.for_stage(stage)
stage_stats.items_produced
stage_stats.items_consumed
stage_stats.throughput
stage_stats.latency_samples

# Pipeline metrics
stats.total_produced
stats.total_consumed
stats.bottleneck
stats.throughput
```

### Task
```ruby
class MyTask
  include Minigun::DSL

  pipeline do
    # Definition
  end
end

task = MyTask.new
task.run                        # Full execution
task.run(background: true)      # Background thread
task.hud                         # Open HUD monitor
task.running?                    # Check if running
task.stop                        # Stop execution
task.wait                        # Wait for completion
```

## Configuration

### Global Configuration
```ruby
class MyTask
  include Minigun::DSL

  max_threads 10
  max_processes 4
  max_retries 3

  pipeline do
    # All stages inherit these defaults
  end
end
```

### Stage Configuration
```ruby
# Queue size
processor :my_stage, queue_size: 500 do |item, output|
  # Bounded queue with 500 slots
end

# Unbounded queue
processor :my_stage, queue_size: Float::INFINITY do |item, output|
  # No queue limit
end

# Execution strategy
processor :my_stage, threads: 10 do |item, output|
  # 10 concurrent threads
end

# Await (for dynamic routing targets)
consumer :dynamic, await: true do |item|
  # Waits indefinitely for items via output.to(:dynamic)
end
```

## Termination Protocol

```
Producer completes
    ↓
    sends EndOfSource to all downstreams
    ↓
InputQueue receives EndOfSource from ALL upstreams
    ↓
    returns EndOfStage sentinel
    ↓
ConsumerStage breaks from loop
    ↓
    sends EndOfSource to its downstreams
    ↓
    cascade continues...
```

## Monitoring

### HUD (Interactive)
```ruby
require 'minigun/hud'

# Automatic
Minigun::HUD.run_with_hud(MyTask)

# Background + HUD
task = MyTask.new
task.run(background: true)
task.hud  # Open HUD, press 'q' to close
```

### Stats API (Programmatic)
```ruby
task = MyTask.new
task.run

stats = task._minigun_task.root_pipeline.stats
puts "Throughput: #{stats.throughput} items/s"
puts "Bottleneck: #{stats.bottleneck.stage_name}"
```

## Performance Tips

### Finding Bottlenecks
1. Use the HUD to identify slowest stage
2. Check throughput: `stats.bottleneck.stage_name`
3. Add concurrency to bottleneck stage

### Adding Concurrency
```ruby
# Too slow?
processor :slow do |item, output|
  expensive_operation(item)
end

# Add threads (I/O-bound)
processor :slow, threads: 20 do |item, output|
  expensive_operation(item)
end

# Add processes (CPU-bound)
ipc_fork 8 do
  processor :slow do |item, output|
    expensive_operation(item)
  end
end
```

### Backpressure
```ruby
# Reduce queue size to limit memory usage
processor :downstream, queue_size: 100 do |item, output|
  # Only 100 items buffered
end
```

## Project Structure

```
lib/minigun/
├── minigun.rb           # Module entry point
├── pipeline.rb          # Pipeline orchestrator
├── stage.rb             # Stage types
├── worker.rb            # Thread wrapper
├── runner.rb            # Job lifecycle
├── task.rb              # Top-level coordinator
├── dag.rb               # Routing graph
├── stats.rb             # Performance metrics
├── queue_wrappers.rb    # Queue abstractions
├── dsl.rb               # User-facing DSL
├── execution/
│   └── executor.rb      # Concurrency strategies
└── hud/                 # HUD components
```

## Key Concepts

### Backpressure
Automatic flow control via bounded queues. When downstream is slow, upstream blocks until space is available.

### Bottleneck
The stage with minimum throughput limits overall pipeline performance:
```
Pipeline throughput = min(stage.throughput for all stages)
```

### Dynamic Routing
Route items to stages without DAG connection:
```ruby
output.to(:specific_stage) << item
```

### Run Modes
- `:autonomous` - Generates data (Producer)
- `:streaming` - Processes queue items (Consumer/Router)
- `:composite` - Manages nested pipeline (PipelineStage)

---

**See Also:**
- [Introduction](guides/01_introduction.md) - Getting started
- [API Reference](guides/09_api_reference.md) - Complete API docs
- [System Architecture](architecture/system_architecture.md) - Internals
