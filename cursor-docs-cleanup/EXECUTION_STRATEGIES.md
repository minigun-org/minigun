# Execution Strategies Design

## Overview

Minigun supports three execution strategies for parallel processing:

1. **:cow_fork** - Copy-On-Write fork (accumulate, then fork)
2. **:ipc_fork** - IPC fork (fork upfront, communicate via sockets)
3. **:ractor** - Ractor-based (Ruby 3.0+, in-memory message passing)

## Architecture

### Unified Execution Model

Both **Stages** and **Pipelines** can use execution strategies, enabling flexible parallelism at any level.

```ruby
# Stages can specify execution strategy
consumer :save, strategy: :cow_fork do |item|
  DB.save(item)
end

# Pipelines can specify execution strategy
pipeline :transform, strategy: :ipc_fork, to: :load do
  producer :clean { ... }
  consumer :output { ... }
end
```

### Hierarchy

```
ExecutionUnit (abstract)
├── Stage (atomic execution unit)
│   ├── ProducerStage
│   ├── ProcessorStage
│   ├── ConsumerStage
│   └── AccumulatorStage
└── Pipeline (composite execution unit)
    └── Can contain Stages or other Pipelines!
```

### Strategy Comparison

| Strategy | When to Use | Fork Timing | Communication | Memory |
|----------|-------------|-------------|---------------|--------|
| `:threaded` | Default, light workloads | Never | Shared memory | Shared |
| `:cow_fork` | Heavy consumers, read-heavy | After accumulation | None (batch) | COW |
| `:ipc_fork` | Process isolation needed | Upfront | Sockets | Isolated |
| `:ractor` | Ruby 3.0+, CPU-bound | Never (threads) | Message passing | Isolated |

## Usage Examples

### 1. COW Fork (Current PublisherBase Pattern)

```ruby
class DataPublisher
  include Minigun::DSL

  max_processes 4

  producer :fetch_ids do
    Model.pluck(:id).each { |id| emit(id) }
  end

  # COW fork: accumulate 2000 items, then fork
  consumer :publish,
           strategy: :cow_fork,
           accumulator_max_single: 2000 do |id|
    object = Model.find(id)
    ElasticSearch.index(object)
  end
end
```

**How it works:**
1. Producer emits items to queue
2. Accumulator collects items until threshold (2000)
3. Fork child process with accumulated batch (COW optimization)
4. Child processes batch, then exits
5. Parent continues accumulating next batch

**Benefits:**
- Memory efficient (COW shares unchanged memory)
- Good for read-heavy operations
- Matches PublisherBase behavior

### 2. IPC Fork

```ruby
class RealtimeProcessor
  include Minigun::DSL

  producer :stream_events do
    EventStream.each { |event| emit(event) }
  end

  # IPC fork: fork upfront, communicate via sockets
  consumer :process,
           strategy: :ipc_fork,
           max_processes: 4 do |event|
    heavy_processing(event)
  end
end
```

**How it works:**
1. Fork N worker processes upfront (based on max_processes)
2. Each worker has a socket pair with parent
3. Parent sends items to workers via socket
4. Workers process and optionally return results
5. Workers stay alive for entire task duration

**Benefits:**
- Complete process isolation
- Workers can maintain state
- Good for long-running tasks
- Better for write-heavy operations

### 3. Ractor (Ruby 3.0+)

```ruby
class ParallelCompute
  include Minigun::DSL

  producer :generate do
    1000.times { |i| emit(i) }
  end

  # Ractor: spawn Ruby actors
  processor :compute,
            strategy: :ractor,
            max_ractors: 8 do |num|
    result = expensive_calculation(num)
    emit(result)
  end

  consumer :collect do |result|
    results << result
  end
end
```

**How it works:**
1. Spawn N ractors upfront
2. Send items to ractors via `Ractor.send`
3. Ractors process in parallel (true parallelism)
4. Receive results via `Ractor.receive`
5. Ractors stay alive for task duration

**Benefits:**
- True parallelism (no GIL!)
- Lower overhead than fork
- Better resource utilization
- Good for CPU-bound work

## Pipeline-Level Strategies

Pipelines can also use execution strategies:

```ruby
class MultiStageETL
  include Minigun::DSL

  # Extract pipeline runs in main process
  pipeline :extract, to: :transform do
    producer :fetch { ... }
    consumer :output { |item| emit(item) }
  end

  # Transform pipeline runs in forked process (IPC)
  pipeline :transform,
           strategy: :ipc_fork,
           to: :load do
    producer :input
    processor :clean { |item| emit(cleaned) }
    consumer :output { |item| emit(item) }
  end

  # Load pipeline uses COW fork for consumers
  pipeline :load, strategy: :cow_fork do
    producer :input
    consumer :save { |item| DB.save(item) }
  end
end
```

**This enables:**
- Pipeline isolation (transform runs in separate process)
- Independent failure domains
- Mixed strategies (different pipelines, different strategies)

## Stage-Level Strategies

Individual stages can specify strategies:

```ruby
class MixedStrategy
  include Minigun::DSL

  producer :source { emit(data) }

  # Processor runs in thread (default)
  processor :validate { |item| emit(item) if valid?(item) }

  # Heavy consumer uses COW fork
  consumer :heavy_save,
           strategy: :cow_fork do |item|
    expensive_save(item)
  end

  # Light consumer uses threads
  consumer :light_log do |item|
    logger.info(item)
  end
end
```

## Implementation Plan

### Phase 1: Strategy Infrastructure ✅
- [x] Create `ExecutionStrategy` module
- [x] Implement `Threaded`, `CowFork`, `IpcFork`, `Ractor` strategies
- [ ] Add `strategy:` option to Stage definitions
- [ ] Add `strategy:` option to Pipeline definitions

### Phase 2: Stage Integration
- [ ] Refactor `ConsumerStage` to use strategies
- [ ] Update `Pipeline#consume_batch` to delegate to strategy
- [ ] Add strategy-specific configuration options
- [ ] Handle strategy cleanup on errors

### Phase 3: Pipeline Integration
- [ ] Make `Pipeline < ExecutionUnit`?
- [ ] Allow pipelines to execute with strategies
- [ ] Enable pipeline-level IPC/Ractor communication
- [ ] Support nested pipelines

### Phase 4: Testing & Examples
- [ ] Unit tests for each strategy
- [ ] Integration tests for mixed strategies
- [ ] Example: COW fork publisher (like PublisherBase)
- [ ] Example: IPC fork for isolation
- [ ] Example: Ractor for CPU-bound work

## Configuration Options

### Global Config

```ruby
class MyTask
  include Minigun::DSL

  max_processes 4        # For :cow_fork and :ipc_fork
  max_threads 10         # For :threaded
  max_ractors 8          # For :ractor

  # Strategy-specific
  accumulator_max_single 2000  # COW fork threshold
  accumulator_max_all 4000     # COW fork total threshold
end
```

### Per-Stage Config

```ruby
consumer :save,
         strategy: :cow_fork,
         accumulator_max_single: 1000,
         max_processes: 2 do |item|
  # ...
end
```

### Per-Pipeline Config

```ruby
pipeline :heavy_processing,
         strategy: :ipc_fork,
         max_processes: 8,
         to: :next do
  # ...
end
```

## Open Questions

1. **Pipeline as Stage**: Should `Pipeline < Stage` or `Pipeline < ExecutionUnit`?
   - Leaning toward: Both inherit from `ExecutionUnit`

2. **Strategy Selection**: Should strategies be per-consumer or per-pipeline?
   - Answer: Both! Stage-level for granular control, Pipeline-level for isolation

3. **Ractor Compatibility**: What about non-shareable objects?
   - Need to document limitations (no DB connections in ractors)

4. **IPC Serialization**: Marshal, JSON, or MessagePack?
   - Start with Marshal (Ruby native), add options later

## Summary

This design provides:

✅ **Flexibility** - Choose strategy per stage or pipeline
✅ **Composability** - Mix strategies in one task
✅ **Performance** - COW fork for memory efficiency
✅ **Isolation** - IPC/Ractor for process separation
✅ **Backward Compatible** - Default to `:threaded`
✅ **PublisherBase Pattern** - COW fork matches original behavior

Next steps: Integrate strategies into Stage and Pipeline classes.

