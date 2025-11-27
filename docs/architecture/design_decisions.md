# Design Decisions

This document explains the key design decisions behind Minigun's architecture and why certain choices were made.

## Table of Contents

- [Why Pipelines?](#why-pipelines)
- [Why Stages Instead of Jobs?](#why-stages-instead-of-jobs)
- [Why Multiple Execution Strategies?](#why-multiple-execution-strategies)
- [Why DAG-Based Routing?](#why-dag-based-routing)
- [Why Queue-Based Communication?](#why-queue-based-communication)
- [Why Signal-Based Termination?](#why-signal-based-termination)
- [Why No External Dependencies?](#why-no-external-dependencies)
- [Why Bounded Queues by Default?](#why-bounded-queues-by-default)
- [Why Composite Pattern for Pipelines?](#why-composite-pattern-for-pipelines)
- [Why Separate Workers and Executors?](#why-separate-workers-and-executors)

---

## Why Pipelines?

### The Problem

Traditional job queue systems (Sidekiq, Resque) are great for discrete, independent jobs, but they struggle with **dependent workflows**:

```ruby
# Traditional approach - fragile
class FetchDataJob
  def perform(user_id)
    data = fetch_data(user_id)
    TransformDataJob.perform_later(data)
  end
end

class TransformDataJob
  def perform(data)
    transformed = transform(data)
    SaveDataJob.perform_later(transformed)
  end
end
```

**Problems:**
- Each step enqueues the next (coupling)
- Hard to see the full workflow
- Failures require complex retry logic
- Can't optimize across steps

### The Solution

**Pipelines** express the entire workflow declaratively:

```ruby
pipeline do
  producer :fetch { fetch_data }
  processor :transform { |data, output| output << transform(data) }
  consumer :save { |data| save_data(data) }
end
```

**Benefits:**
- Entire workflow visible at once
- Automatic data flow between steps
- Optimize the whole pipeline (find bottlenecks)
- Built-in error handling and retry

**Decision:** Pipelines are the fundamental abstraction because they model complex workflows better than independent jobs.

---

## Why Stages Instead of Jobs?

### The Problem

In job systems, every unit of work is the same: a job. This makes complex patterns awkward:

```ruby
# How to model a producer?
class DataGeneratorJob
  def perform
    1000.times { |i| ProcessItemJob.perform_later(i) }
  end
end

# How to model batching?
class BatchCollectorJob
  def perform(item)
    # Collect items in Redis?
    # How to know when batch is full?
  end
end
```

### The Solution

**Specialized stage types** for common patterns:

- **Producer** - Generates data (no input, only output)
- **Processor** - Transforms data (input and output)
- **Accumulator** - Batches items
- **Consumer** - Final processing (input, no output)

Each stage type has semantics that match its purpose:

```ruby
producer :generate do |output|
  # Only emits, doesn't consume
  1000.times { |i| output << i }
end

accumulator :batch, max_size: 100 do |batch, output|
  # Automatically collects 100 items before emitting
  output << batch
end

consumer :save do |batch|
  # Only consumes, doesn't emit
  save_batch(batch)
end
```

**Decision:** Different stage types make common patterns explicit and easy to express.

---

## Why Multiple Execution Strategies?

### The Problem

One-size-fits-all concurrency doesn't work:

- **I/O-bound work** (API calls, database queries) benefits from threads
- **CPU-bound work** (image processing, ML inference) needs processes
- **Large shared data** benefits from copy-on-write forks
- **Persistent workers** amortize setup costs

### The Solution

**Pluggable executors** that separate "what to do" from "how to do it":

```ruby
# Same business logic, different execution:

# Threads for I/O
processor :fetch_api, execution: :thread, threads: 50 do |url, output|
  output << HTTP.get(url)
end

# COW forks for CPU + shared data
processor :classify_image, execution: :cow_fork, max: 8 do |image, output|
  output << @model.predict(image)  # @model shared via COW
end

# IPC forks for persistent workers
processor :inference, execution: :ipc_fork, max: 4 do |data, output|
  @model ||= load_expensive_model  # Loaded once per worker
  output << @model.predict(data)
end
```

**Decision:** Multiple execution strategies let you optimize each stage independently.

---

## Why DAG-Based Routing?

### The Problem

Linear pipelines are limiting. Real workflows have:
- Fan-out (one source, multiple consumers)
- Fan-in (multiple sources, one consumer)
- Conditional routing
- Parallel paths

### The Solution

A **Directed Acyclic Graph (DAG)** represents arbitrary routing:

```ruby
producer :source, to: [:path_a, :path_b]  # Fan-out
processor :path_a, to: :merge
processor :path_b, to: :merge
consumer :merge, from: [:path_a, :path_b]  # Fan-in
```

**Why DAG?**
- Represents any pipeline topology
- Enables cycle detection (prevents infinite loops)
- Supports topological sorting (execution order)
- Validates connections before running

**Why not a general graph?**
- Cycles create infinite loops
- DAG guarantees termination

**Decision:** DAG routing enables complex workflows while maintaining safety.

---

## Why Queue-Based Communication?

### The Problem

Direct method calls couple stages tightly:

```ruby
# Tight coupling
class StageA
  def process(item)
    stage_b.process(transform(item))
  end
end
```

**Problems:**
- Can't parallelize easily
- Can't add backpressure
- Can't route dynamically
- Hard to monitor

### The Solution

**Queues decouple stages**:

```ruby
# Stage A
output_queue << transformed_item

# Stage B (different thread/process)
item = input_queue.pop
```

**Benefits:**
- **Parallelism** - Stages run concurrently
- **Backpressure** - Bounded queues slow fast producers
- **Isolation** - Works across process boundaries
- **Monitoring** - Observe queue depths
- **Flexibility** - Insert stages, change routing

**Decision:** Queue-based communication enables parallelism, backpressure, and process isolation.

---

## Why Signal-Based Termination?

### The Problem

How do stages know when to stop?

**Bad approaches:**
- **Timeout** - Arbitrary, might cut off valid work
- **Polling flag** - Every stage must check flag
- **Closing queues** - Ruby's Queue doesn't support this cleanly

### The Solution

**Signals** flow through the pipeline like data:

```ruby
# Producer finishes
output_queue << EndOfSource.new(:producer)

# Consumer receives signal
loop do
  item = input_queue.pop
  break if item == EndOfStage  # All upstreams done
  process(item)
end
```

**How it works:**
1. Producer sends `EndOfSource` to downstream
2. `InputQueue` tracks signals from all upstreams
3. When all upstreams done, return `EndOfStage` to consumer
4. Consumer exits and sends `EndOfSource` downstream
5. Cascade continues until all stages complete

**Benefits:**
- Clean shutdown (no orphaned threads)
- Works with complex routing (fan-in, fan-out)
- No polling or timeouts needed
- Graceful under backpressure

**Decision:** Signal-based termination provides clean, predictable shutdown for complex pipelines.

---

## Why No External Dependencies?

### The Problem

Dependencies add:
- Installation complexity
- Version conflicts
- Operational overhead (Redis, databases)
- Deployment constraints

### The Solution

**Pure Ruby implementation**:
- Uses only Ruby stdlib (Thread, Queue, Process)
- No Redis, PostgreSQL, or message brokers
- Runs anywhere Ruby runs

**Trade-offs:**

❌ **What you lose:**
- Persistent queues (jobs lost on crash)
- Distributed workers (multi-machine)
- Job scheduling (cron-like features)

✅ **What you gain:**
- Zero setup (gem install and go)
- No operational burden
- Fast development iteration
- Works in any environment

**When to use Minigun:**
- In-memory processing pipelines
- Data transformations
- Batch jobs that run to completion
- Testing and development

**When to use Sidekiq/Resque:**
- Need persistence (survive crashes)
- Multi-machine distribution
- Job scheduling

**Decision:** No dependencies makes Minigun easy to use for its target use case (in-memory pipelines).

---

## Why Bounded Queues by Default?

### The Problem

Unbounded queues can exhaust memory:

```ruby
# Fast producer, slow consumer
producer :generate do |output|
  1_000_000.times { |i| output << i }  # Fast
end

consumer :process do |item|
  sleep 0.1  # Slow - 10/second
  process(item)
end

# Without bounds: queue grows to 1M items = memory exhaustion
```

### The Solution

**SizedQueue with default limit (1000)**:

```ruby
# Automatic backpressure
queue = SizedQueue.new(1000)

# Producer blocks when queue is full
queue << item  # Blocks if queue has 1000 items
```

**How it works:**
1. Consumer is slow, queue fills up
2. Producer tries to push 1001st item
3. Producer **blocks** until consumer makes space
4. Automatic flow control - no memory exhaustion

**Override when needed:**
```ruby
# Larger buffer
processor :stage, queue_size: 10_000

# Unbounded (use carefully!)
processor :stage, queue_size: Float::INFINITY
```

**Decision:** Bounded queues prevent memory exhaustion by default, with opt-out for advanced users.

---

## Why Composite Pattern for Pipelines?

### The Problem

How to reuse pipeline components?

**Bad approach:**
```ruby
# Copy-paste pipeline logic everywhere
class TaskA
  pipeline do
    # 20 lines of common logic
  end
end

class TaskB
  pipeline do
    # Same 20 lines duplicated
  end
end
```

### The Solution

**Nested pipelines** treated as stages:

```ruby
class ReusableETL
  include Minigun::DSL

  pipeline do
    producer :extract { ... }
    processor :transform { ... }
    consumer :load { ... }
  end
end

class MainPipeline
  include Minigun::DSL

  pipeline do
    producer :fetch_data { ... }

    # Nest the reusable pipeline
    nested_pipeline ReusableETL, :etl

    consumer :final_processing { ... }
  end
end
```

**How it works:**
- `PipelineStage` wraps nested pipelines
- Entrance/Exit stages route data in/out
- Transparent to parent pipeline

**Benefits:**
- Reuse common patterns
- Compose complex systems
- Test pipelines independently
- Clean abstractions

**Decision:** Composite pattern enables reusable pipeline components.

---

## Why Separate Workers and Executors?

### The Problem

Stage execution involves two concerns:

1. **Thread management** - One thread per stage
2. **Concurrency strategy** - How to parallelize work

Mixing these in one class creates complexity.

### The Solution

**Separation of responsibilities:**

**Worker:**
- Creates one thread per stage
- Manages stage lifecycle
- Builds stage context
- Delegates to executor

**Executor:**
- Determines HOW stage executes
- Creates thread pools, forks processes
- Implements concurrency strategy

```ruby
# Worker (lifecycle)
class Worker
  def run
    thread = Thread.new do
      executor = create_executor  # Delegation
      executor.execute_stage(stage, context, ...)
    end
  end
end

# Executor (concurrency)
class ThreadPoolExecutor
  def execute_stage(stage, ...)
    thread_pool.execute { stage.execute(...) }
  end
end
```

**Benefits:**
- Clear separation of concerns
- Easy to add new executors
- Worker logic stays simple
- Executors are pluggable

**Decision:** Separating Worker and Executor makes the codebase maintainable and extensible.

---

## Summary of Principles

1. **Pipelines over jobs** - Express workflows declaratively
2. **Specialized stages** - Match patterns to purpose
3. **Pluggable execution** - Optimize per stage
4. **DAG routing** - Enable complex workflows safely
5. **Queue-based communication** - Decouple and parallelize
6. **Signal-based termination** - Clean shutdown
7. **Zero dependencies** - Easy setup, fast iteration
8. **Bounded queues** - Prevent memory exhaustion
9. **Composite pattern** - Reusable components
10. **Separation of concerns** - Maintainable codebase

## Trade-offs

Every design decision involves trade-offs. Minigun optimizes for:

✅ **Strengths:**
- In-memory data pipelines
- Complex multi-stage workflows
- Easy development and testing
- Fine-grained concurrency control

❌ **Weaknesses:**
- No job persistence (use Sidekiq for that)
- No cross-machine distribution
- No built-in scheduling

**Know your use case** and choose the right tool!

---

**See Also:**
- [System Architecture](system_architecture.md) - How it all fits together
- [When to Use Minigun](../comparison.md) - Decision guide
- [Extending Minigun](../advanced/extending.md) - Build on these foundations
