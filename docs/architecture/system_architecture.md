# System Architecture

This document explains how Minigun works under the hood. Understanding the architecture will help you build better pipelines and debug issues effectively.

## High-Level Overview

Minigun's architecture consists of several layers:

```
┌─────────────────────────────────────────────────────┐
│                   User DSL Layer                    │
│ (pipeline do, producer, processor, consumer, etc.)  │
└───────────────────┬─────────────────────────────────┘
                    │
┌───────────────────▼─────────────────────────────────┐
│                   Task Layer                        │
│     (coordinates root pipeline, configuration)      │
└───────────────────┬─────────────────────────────────┘
                    │
┌───────────────────▼─────────────────────────────────┐
│                 Pipeline Layer                      │
│   (manages stages, builds DAG, creates queues)      │
└───────────────────┬─────────────────────────────────┘
                    │
        ┌───────────┴──────────┬──────────────┐
        │                      │              │
┌───────▼────────┐   ┌─────────▼───────┐  ┌───▼───────┐
│   Stage        │   │      DAG        │  │  Stats    │
│ (business      │   │  (routing       │  │ (metrics) │
│  logic)        │   │   graph)        │  │           │
└────────┬───────┘   └─────────────────┘  └───────────┘
         │
┌────────▼────────────────────────────────────────────┐
│              Execution Layer                        │
│  ┌────────────┐  ┌──────────┐  ┌─────────────────┐  │
│  │   Worker   │  │ Executor │  │  Queue System   │  │
│  │  (thread   │  │ (thread/ │  │ (InputQueue/    │  │
│  │  wrapper)  │  │  fork)   │  │  OutputQueue)   │  │
│  └────────────┘  └──────────┘  └─────────────────┘  │
└─────────────────────────────────────────────────────┘
```

## Core Components

### 1. Task

The **top-level coordinator** that holds everything together.

**Responsibilities:**
- Holds the root pipeline
- Manages stage registry for name resolution
- Tracks queue registry (stage → queue mappings)
- Handles IPC pipe lifecycle
- Stores global configuration

**Code Location:** `lib/minigun/task.rb`

```ruby
class MyTask
  include Minigun::DSL  # Creates a Task instance

  pipeline do
    # Pipeline definition
  end
end

# Behind the scenes:
# - Creates Minigun::Task instance
# - Stores pipeline definition
# - Builds stage registry
```

### 2. Pipeline

The **orchestrator** that manages stages and their connections.

**Responsibilities:**
- Registers stages
- Builds and validates the DAG (Directed Acyclic Graph)
- Creates queues between stages
- Executes lifecycle hooks
- Aggregates statistics
- Spawns Workers for each stage

**Code Location:** `lib/minigun/pipeline.rb`

**Key Methods:**
- `add_stage(type, name, options, &block)` - Register a stage
- `build_dag_routing!` - Construct routing graph
- `run(context, job_id: nil)` - Execute the pipeline

### 3. Stage

The **business logic units** that process data.

**Stage Hierarchy:**
```
Stage (base class)
├── ProducerStage     (run_mode: :autonomous)
├── ConsumerStage     (run_mode: :streaming)
│   └── AccumulatorStage
├── RouterStage       (run_mode: :streaming)
│   ├── RouterBroadcastStage
│   └── RouterRoundRobinStage
└── PipelineStage     (run_mode: :composite)
    ├── EntranceStage
    └── ExitStage
```

**Run Modes:**
- **`:autonomous`** - Generates data independently (ProducerStage)
- **`:streaming`** - Processes items from queue (ConsumerStage, RouterStage)
- **`:composite`** - Manages nested pipeline (PipelineStage)

**Code Location:** `lib/minigun/stage.rb`

**Key Methods:**
- `run_mode` - Returns the execution mode
- `execute(context, item:, input_queue:, output_queue:)` - Process one item
- `emit(item)` - Send item downstream

### 4. Worker

A **thread wrapper** that manages stage execution.

**Responsibilities:**
- Creates execution thread for each stage
- Creates StageContext (tracks sources, queues, stats)
- Creates and manages Executor
- Handles disconnected stage detection
- Invokes `Stage#run_stage`

**Code Location:** `lib/minigun/worker.rb`

**Lifecycle:**
```ruby
# When pipeline runs:
worker = Worker.new(stage, pipeline, context)
worker.start  # Creates thread

# Inside thread:
stage_ctx = build_stage_context
executor = create_executor
stage.run_stage(stage_ctx)
```

### 5. DAG (Directed Acyclic Graph)

The **routing graph** that defines how stages connect.

**Responsibilities:**
- Stores stage connections as edges
- Validates no cycles exist (using TSort)
- Provides upstream/downstream queries
- Identifies sources and terminals

**Code Location:** `lib/minigun/dag.rb`

**Key Methods:**
- `add_edge(from_stage, to_stage)` - Connect stages
- `upstream(stage)` - Get all sources feeding this stage
- `downstream(stage)` - Get all destinations this stage feeds
- `validate!` - Check for cycles

**Example:**
```ruby
# Pipeline: A → B → C
#               ↘ D

dag.add_edge(stage_a, stage_b)
dag.add_edge(stage_b, stage_c)
dag.add_edge(stage_b, stage_d)

dag.downstream(stage_b)  # => [stage_c, stage_d]
dag.upstream(stage_c)    # => [stage_b]
```

### 6. Executor

The **concurrency strategy** that determines HOW stages execute.

**Executor Types:**
- **InlineExecutor** - Sequential, single-threaded
- **ThreadPoolExecutor** - Concurrent threads
- **CowForkExecutor** - Fork per item with COW
- **IpcForkExecutor** - Persistent worker processes with IPC

**Code Location:** `lib/minigun/execution/executor.rb`

**Key Methods:**
- `execute_stage(stage, context, input_queue, output_queue)` - Execute with concurrency
- `shutdown` - Clean up resources

### 7. Queue System

The **data transport** between stages.

**Components:**

**SizedQueue (Ruby stdlib):**
- Bounded queue with max capacity
- Provides automatic backpressure
- Blocks producers when full

**InputQueue Wrapper:**
- Wraps SizedQueue
- Tracks EndOfSource signals from upstream stages
- Returns EndOfStage sentinel when all upstreams done

**OutputQueue Wrapper:**
- Routes items to multiple downstream queues
- Handles dynamic routing with `output.to(:stage_name)`
- Distributes to all connected stages

**Code Location:** `lib/minigun/queue_wrappers.rb`

### 8. Statistics

The **metrics collector** for performance monitoring.

**Per-Stage Metrics:**
- Items produced/consumed/failed
- Latency samples (reservoir sampling)
- Start/end times
- Throughput calculations

**Pipeline-Level Metrics:**
- Total items processed
- Overall throughput
- Bottleneck identification
- Total runtime

**Code Location:** `lib/minigun/stats.rb`

## Data Flow

Let's trace how data flows through a simple pipeline:

### Example Pipeline

```ruby
pipeline do
  producer :generate do |output|
    3.times { |i| output << i }
  end

  processor :double do |n, output|
    output << n * 2
  end

  consumer :print do |n|
    puts n
  end
end
```

### Step-by-Step Execution

#### 1. Pipeline Construction

```ruby
# When pipeline block executes:
pipeline.add_stage(:producer, :generate, {}, &block)
pipeline.add_stage(:processor, :double, {}, &block)
pipeline.add_stage(:consumer, :print, {}, &block)

# Build DAG:
dag.add_edge(generate, double)
dag.add_edge(double, print)
dag.validate!  # Checks for cycles
```

#### 2. Queue Creation

```ruby
# Pipeline creates queues between stages:
double_input_queue = SizedQueue.new(1000)
print_input_queue = SizedQueue.new(1000)

# Store in registry:
queue_registry[double] = double_input_queue
queue_registry[print] = print_input_queue
```

#### 3. Worker Creation

```ruby
# Pipeline creates one Worker per stage:
workers = [
  Worker.new(generate_stage, pipeline, context),
  Worker.new(double_stage, pipeline, context),
  Worker.new(print_stage, pipeline, context)
]

# Start all workers (creates threads):
workers.each(&:start)
```

#### 4. Producer Execution

```ruby
# In generate worker thread:
output_queue = OutputQueue.new(
  downstream_queues: [double_input_queue]
)

# User block executes:
3.times { |i| output_queue << i }

# Sends:
#   double_input_queue << 0
#   double_input_queue << 1
#   double_input_queue << 2

# Then sends end signal:
double_input_queue << EndOfSource.new(:generate)
```

#### 5. Processor Execution

```ruby
# In double worker thread:
input_queue = InputQueue.new(
  queue: double_input_queue,
  sources_expected: 1  # Only 'generate' feeds this
)

output_queue = OutputQueue.new(
  downstream_queues: [print_input_queue]
)

# Loop until done:
loop do
  item = input_queue.pop  # Blocks waiting for items

  if item == EndOfStage
    # All upstreams done
    break
  end

  # Process item:
  result = item * 2
  output_queue << result
end

# Send end signal:
print_input_queue << EndOfSource.new(:double)
```

#### 6. Consumer Execution

```ruby
# In print worker thread:
input_queue = InputQueue.new(
  queue: print_input_queue,
  sources_expected: 1
)

loop do
  item = input_queue.pop

  if item == EndOfStage
    break
  end

  # Final processing:
  puts item
end

# No downstream, so no end signals to send
```

#### 7. Pipeline Completion

```ruby
# Main thread waits for all workers:
workers.each(&:join)

# Pipeline returns statistics:
{
  status: :completed,
  stats: pipeline.stats,
  duration: end_time - start_time
}
```

## Termination Protocol

Understanding how pipelines shut down cleanly:

### Signal Types

**EndOfSource:**
- Sent by a stage when it finishes producing
- Contains the source stage name
- Received by downstream InputQueues

**EndOfStage:**
- Returned by InputQueue to the consuming stage
- Signals that all upstreams have finished
- Triggers stage shutdown

### Termination Flow

```
1. Producer finishes generating data
   ↓
2. Producer calls send_end_signals()
   ↓
3. EndOfSource pushed to all downstream queues
   ↓
4. Downstream InputQueue receives EndOfSource
   ↓
5. InputQueue tracks: have all upstreams sent EndOfSource?
   ↓
6. When all upstreams done: return EndOfStage to consumer
   ↓
7. Consumer breaks from loop
   ↓
8. Consumer calls send_end_signals()
   ↓
9. Cascade continues downstream
   ↓
10. All stages eventually shutdown
```

### Example with Fan-In

```ruby
# Two producers feed one consumer:
producer :a, to: :merge do |output|
  output << 1
end

producer :b, to: :merge do |output|
  output << 2
end

consumer :merge, from: [:a, :b] do |item|
  puts item
end
```

**Termination:**
```
1. Producer A finishes → sends EndOfSource(:a)
2. Producer B finishes → sends EndOfSource(:b)
3. Merge's InputQueue receives both signals
4. InputQueue checks: received EndOfSource from A? ✓
5. InputQueue checks: received EndOfSource from B? ✓
6. All upstreams done → return EndOfStage
7. Merge stage shuts down
```

## Thread Model

### Single Pipeline Thread Model

```
Main Thread
  │
  ├─→ Worker Thread (Producer)
  │   └─→ Stage executes, emits to queue
  │
  ├─→ Worker Thread (Processor)
  │   ├─→ Stage loops on input queue
  │   └─→ Executor creates thread pool
  │       ├─→ Thread 1 (processing item)
  │       ├─→ Thread 2 (processing item)
  │       └─→ Thread N (processing item)
  │
  └─→ Worker Thread (Consumer)
      ├─→ Stage loops on input queue
      └─→ Executor creates thread pool
          └─→ Threads process items
```

**Key Points:**
- One Worker thread per stage
- Executor creates additional threads for concurrency
- All threads share memory (except IPC/COW forks)

### With Fork Executors

```
Main Process
  │
  ├─→ Worker Thread (Producer)
  │
  ├─→ Worker Thread (Processor - COW Fork)
  │   └─→ Parent Loop
  │       ├─→ Fork Child 1 (process item, exit)
  │       ├─→ Fork Child 2 (process item, exit)
  │       └─→ Fork Child N (process item, exit)
  │
  └─→ Worker Thread (Consumer - IPC Fork)
      └─→ Parent Loop
          ├─→ Persistent Worker Process 1
          ├─→ Persistent Worker Process 2
          └─→ Persistent Worker Process N
```

## Memory Model

### Thread Execution

```
┌─────────────────────────────────────┐
│         Shared Process Memory       │
│                                     │
│  ┌────────┐  ┌────────┐  ┌────────┐│
│  │Thread 1│  │Thread 2│  │Thread 3││
│  │        │  │        │  │        ││
│  └────────┘  └────────┘  └────────┘│
│      ↓           ↓           ↓     │
│  All threads access same objects   │
└─────────────────────────────────────┘
```

**Characteristics:**
- Shared memory (fast, no serialization)
- Subject to GVL (limits CPU parallelism)
- Must use Mutex for shared state

### COW Fork Execution

```
Parent Process Memory (50MB)
  ├─→ @large_dataset
  └─→ @config

Fork Child 1 ──→ Copy-On-Write View
  │              (reads parent's memory)
  └─→ Process item, write result, exit

Fork Child 2 ──→ Copy-On-Write View
  └─→ Process item, write result, exit
```

**Characteristics:**
- Memory shared until written (COW)
- No serialization needed
- True parallelism (no GVL)
- Auto-cleanup when child exits

### IPC Fork Execution

```
Parent Process
  │
  ├─→ Worker Process 1 (isolated memory)
  │   │
  │   └─→ Bidirectional Pipe
  │       ├─→ Read items (deserialized)
  │       └─→ Write results (serialized)
  │
  ├─→ Worker Process 2 (isolated memory)
  └─→ Worker Process N (isolated memory)
```

**Characteristics:**
- Completely isolated memory
- Data serialized (Marshal or MessagePack)
- True parallelism (no GVL)
- Workers persist for many items

## Configuration Cascade

Configuration cascades from Task → Pipeline → Stage:

```
Task Level (global defaults)
  ↓
Pipeline Level (pipeline-specific)
  ↓
Stage Level (stage-specific, highest priority)
```

**Example:**
```ruby
class MyTask
  include Minigun::DSL

  max_threads 10          # Task level

  pipeline do
    execution :thread     # Pipeline level

    processor :a, threads: 5 do  # Stage level (wins)
      # Uses 5 threads
    end

    processor :b do       # Inherits from pipeline
      # Uses pipeline's thread config
    end
  end
end
```

## Key Design Principles

### 1. Separation of Concerns

- **Stage** = WHAT (business logic)
- **Executor** = HOW (concurrency)
- **Worker** = WHO (thread management)
- **DAG** = WHERE (routing)

### 2. Queue-Based Communication

All inter-stage communication happens via queues:
- Enables process isolation
- Provides automatic backpressure
- Decouples stages

### 3. Signal-Based Termination

EndOfSource/EndOfStage signals ensure clean shutdown:
- No deadlocks
- Graceful cascading termination
- Works with complex routing

### 4. Composite Pattern

PipelineStage wraps nested pipelines:
- Enables hierarchical composition
- Pipelines as stages
- Transparent to parent

### 5. DAG-Driven Routing

All connections defined in DAG before execution:
- Enables validation (cycle detection)
- Supports topological sort
- Resolves forward references

## Summary

Minigun's architecture is designed for:
- **Flexibility** - Multiple execution strategies
- **Composability** - Nest pipelines, reuse stages
- **Performance** - Efficient parallelism, automatic backpressure
- **Observability** - Built-in stats, HUD monitoring
- **Safety** - Validated routing, clean termination

Understanding these internals helps you:
- Build better pipelines
- Debug issues effectively
- Optimize performance
- Extend Minigun with custom components

## Next Steps

- [Pipeline & DAG](pipeline_and_dag.md) - Deep dive into routing
- [Stage Execution Model](stage_execution.md) - How stages run
- [Queue System](queue_system.md) - Data flow internals
- [Termination Protocol](termination_protocol.md) - Shutdown mechanics

---

**See Also:**
- [API Reference](09_api_reference.md) - Complete API docs
- [Extending Minigun](../advanced/extending.md) - Custom executors
- [Source Code](../../lib/minigun/) - Read the implementation
