# Execution Strategies - Final Design

## Strategy Names

| Strategy | Pattern | Use Case |
|----------|---------|----------|
| `:threaded` | In-process threads | Default, lightweight, shared memory |
| `:fork_accumulate` | Accumulate → Fork (COW) | Batch processing, PublisherBase pattern |
| `:fork_ipc` | Fork → IPC sockets | Process isolation, long-running workers |
| `:ractor` | Ractor per item | True parallelism, Ruby 3.0+ |
| `:ractor_accumulate` | Accumulate → Ractors | Batch processing with true parallelism |

## DSL Methods

### Consumer Definitions

```ruby
# Regular consumer (default: threaded)
consumer :save do |item|
  DB.save(item)
end

# Fork with accumulation (COW optimization)
fork_accumulate :heavy_processor do |item|
  expensive_operation(item)
end

# Fork with IPC (process isolation)
fork_ipc :isolated_worker do |item|
  stateful_processing(item)
end

# Ractor accumulation (Ruby 3.0+, true parallelism)
ractor_accumulate :parallel_compute do |item|
  cpu_intensive_work(item)
end
```

### Strategy Option

```ruby
# Explicit strategy option
consumer :custom, strategy: :fork_accumulate do |item|
  process(item)
end

processor :validate, strategy: :threaded do |item|
  emit(item) if valid?(item)
end
```

### Backward Compatibility

```ruby
# Old names still work (aliased)
cow_fork :old_style do |item|
  # Automatically uses :fork_accumulate strategy
end

ipc_fork :old_ipc do |item|
  # Automatically uses :fork_ipc strategy
end
```

## Strategy Comparison

### `:threaded` (Default)

**How it works:**
- Executes in threads within the main process
- Shared memory between threads
- GIL-limited parallelism

**Best for:**
- Light workloads
- I/O-bound tasks
- Quick operations
- Minimal overhead needed

**Example:**
```ruby
consumer :log, strategy: :threaded do |item|
  logger.info("Processed: #{item}")
end
```

### `:fork_accumulate` (PublisherBase Pattern)

**How it works:**
1. Accumulate items in memory until threshold (e.g., 2000 items)
2. Fork child process with accumulated batch
3. Process batch in child (Copy-On-Write optimization)
4. Child exits, parent continues accumulating

**Best for:**
- Heavy batch processing
- Read-heavy operations (COW efficient)
- Large datasets
- ElasticSearch indexing, database updates

**Configuration:**
```ruby
consumer :bulk_index,
         strategy: :fork_accumulate,
         accumulator_max_single: 2000,
         max_processes: 4 do |item|
  ElasticSearch.index(item)
end
```

**Benefits:**
- Memory efficient (COW shares unchanged pages)
- Process isolation
- Matches original PublisherBase behavior

### `:fork_ipc` (Process Isolation)

**How it works:**
1. Fork N worker processes upfront
2. Create socket pairs for parent-child IPC
3. Parent sends items to workers via sockets
4. Workers process and optionally return results
5. Workers stay alive for entire task

**Best for:**
- Process isolation required
- Stateful workers
- Long-running tasks
- Write-heavy operations

**Configuration:**
```ruby
consumer :stateful_processor,
         strategy: :fork_ipc,
         max_processes: 4 do |item|
  # Worker maintains state between items
  @state ||= {}
  @state[item[:key]] = process(item)
end
```

**Benefits:**
- Complete process isolation
- Workers can maintain state
- No GIL limitations
- Good for write-heavy operations

### `:ractor` (True Parallelism)

**How it works:**
- Create ractor per item (or per batch)
- Send items via `Ractor.send`
- True parallel execution (no GIL!)
- Ractors have isolated memory

**Best for:**
- CPU-bound work
- Ruby 3.0+
- True parallelism needed
- Stateless operations

**Limitations:**
- Objects must be shareable (no DB connections in ractors!)
- Ruby 3.0+ only
- More restrictive than threads

**Example:**
```ruby
processor :compute,
          strategy: :ractor do |num|
  # CPU-intensive calculation
  result = expensive_math(num)
  emit(result)
end
```

### `:ractor_accumulate` (New!)

**How it works:**
1. Accumulate items until threshold
2. Distribute batch across N ractors
3. Each ractor processes its slice in parallel
4. Wait for all ractors to finish

**Best for:**
- Batch CPU-bound work
- Ruby 3.0+
- Alternative to fork_accumulate without forking overhead
- Pure computation (no I/O)

**Configuration:**
```ruby
consumer :parallel_compute,
         strategy: :ractor_accumulate,
         accumulator_max_single: 1000,
         max_ractors: 8 do |item|
  # Pure CPU work, no I/O
  result = matrix_multiply(item)
  save_result(result)
end
```

**Benefits:**
- True parallelism without fork overhead
- Lower memory usage than fork
- Better CPU utilization
- No process management complexity

**Trade-offs:**
- Ruby 3.0+ only
- Shareable objects only
- Can't use DB connections directly

## Configuration Options

### Global (Task-level)

```ruby
class MyTask
  include Minigun::DSL

  max_threads 10              # For :threaded
  max_processes 4             # For :fork_accumulate, :fork_ipc
  max_ractors 8               # For :ractor, :ractor_accumulate

  accumulator_max_single 2000  # Threshold for accumulation strategies
  accumulator_max_all 4000     # Total threshold across all accumulators
end
```

### Per-Stage

```ruby
consumer :custom,
         strategy: :fork_accumulate,
         accumulator_max_single: 1000,
         max_processes: 2 do |item|
  # Stage-specific config overrides global
end
```

## Examples

### PublisherBase Pattern (Original)

```ruby
class DataPublisher
  include Minigun::DSL

  max_processes 4

  producer :fetch_ids do
    Model.pluck(:id).each { |id| emit(id) }
  end

  # Fork with accumulation (PublisherBase pattern)
  fork_accumulate :publish,
                  accumulator_max_single: 2000 do |id|
    object = Model.find(id)
    ElasticSearch.index(object)
  end
end
```

### Mixed Strategies

```ruby
class MixedPipeline
  include Minigun::DSL

  producer :generate { emit_items }

  # Light processor: threaded
  processor :validate, strategy: :threaded do |item|
    emit(item) if valid?(item)
  end

  # Heavy consumer: fork with accumulation
  fork_accumulate :heavy_save do |item|
    expensive_save(item)
  end

  # Light consumer: threaded
  consumer :log, strategy: :threaded do |item|
    logger.info(item)
  end
end
```

### Ruby 3.0+ with Ractors

```ruby
class ParallelCompute
  include Minigun::DSL

  producer :generate do
    1000.times { |i| emit(i) }
  end

  # CPU-bound work with ractor accumulation
  ractor_accumulate :compute,
                    accumulator_max_single: 100,
                    max_ractors: 8 do |num|
    # Pure computation, no I/O
    result = fibonacci(num)
    Results.add(result)  # Must use ractor-safe storage
  end
end
```

## Migration Guide

### From PublisherBase

**Before (PublisherBase):**
```ruby
class MyPublisher < PublisherBase
  def consume_object(object)
    ElasticSearch.index(object)
  end
end
```

**After (Minigun):**
```ruby
class MyPublisher
  include Minigun::DSL

  producer :fetch_objects do
    Model.find_each { |obj| emit(obj) }
  end

  fork_accumulate :index do |object|
    ElasticSearch.index(object)
  end
end
```

### From Old Names

**Before:**
```ruby
cow_fork :processor do |item|
  process(item)
end

ipc_fork :worker do |item|
  work(item)
end
```

**After (still works, but prefer new names):**
```ruby
fork_accumulate :processor do |item|
  process(item)
end

fork_ipc :worker do |item|
  work(item)
end
```

## Summary

✅ **5 execution strategies** for different workloads
✅ **Clean naming** - `fork_accumulate`, `fork_ipc`, `ractor_accumulate`
✅ **Backward compatible** - old names aliased
✅ **Flexible** - per-stage or global configuration
✅ **PublisherBase pattern** - `fork_accumulate` matches original behavior
✅ **Ruby 3.0+ ready** - ractor strategies available

**All 121 tests passing!** ✅

