# Process Pool IPC Design

## Two Types of Forking

### 1. COW Fork (`process_per_batch`) - ForkContext
**Pattern**: One-time use, Copy-on-Write
- Spawns a NEW process for each batch
- Process executes once and terminates
- Results marshaled back via pipe
- Efficient for batch processing (COW memory sharing)
- **Use case**: Heavy CPU work on batches, memory isolation

```ruby
process_per_batch(max: 4) do
  consumer :heavy_work do |batch|
    batch.each { |item| expensive_computation(item) }
  end
end
```

**Implementation**: `ForkContext`
- `execute(&block)`: Fork, run block, marshal result, exit
- `join`: Wait for child, unmarshal result
- Process dies after each use

### 2. IPC Process Pool (`processes(N)`) - ProcessPoolContext  
**Pattern**: Persistent workers, IPC communication
- Spawns N worker processes that stay alive
- Each worker processes multiple items over time
- Items sent to workers via Marshal/pipe
- Results received from workers via Marshal/pipe
- **Use case**: Sustained processing, avoid fork overhead

```ruby
processes(4) do
  processor :parse do |item|
    # This worker stays alive and processes many items
    parse_item(item)
  end
end
```

**Implementation**: `ProcessPoolContext` (NEW)
- `spawn_worker`: Fork once, enter event loop
- `execute(&block)`: Marshal block to worker via input pipe
- Worker loop: receive → process → send result → repeat
- `join`: Unmarshal result from output pipe
- `terminate`: Send :SHUTDOWN signal, worker exits gracefully

## Architecture

```
Parent Process
    |
    ├─> ForkContext (COW)
    |   └─> fork() → execute → marshal result → exit
    |       (dies after each use)
    |
    └─> ProcessPoolContext (IPC)
        └─> fork() → spawn_worker()
            └─> loop:
                ├─ receive item (Marshal.load from input_pipe)
                ├─ execute block
                ├─ send result (Marshal.dump to output_pipe)
                └─ repeat until :SHUTDOWN
```

## IPC Pipes

```
ProcessPoolContext:
  
  Parent                          Worker
    |                               |
    | input_writer ──────────────> | input_reader
    |  (send items)                 |  (receive items)
    |                               |
    | output_reader <────────────── | output_writer
    |  (receive results)            |  (send results)
```

## Key Differences

| Feature | ForkContext (COW) | ProcessPoolContext (IPC) |
|---------|-------------------|--------------------------|
| Lifetime | One execution | Persistent |
| Overhead | Fork per batch | Fork once |
| Memory | COW shared | Fully isolated |
| Communication | One-way (result only) | Bidirectional (items + results) |
| Use Case | Batch processing | Sustained processing |
| DSL | `process_per_batch` | `processes(N) do` |

## Why This Matters

**Before**: Both used `ForkContext`, which meant:
- `processes(4)` was forking 4 times PER ITEM (wasteful!)
- No actual process pool reuse
- All processes in same PID (no fork happening)

**After**: Proper separation:
- `processes(4)` spawns 4 workers ONCE, reuses them
- `process_per_batch(max: 4)` forks on-demand for batches
- Real IPC communication for process pools
- Different PIDs for each worker

## Example: When to Use Which

### Use ForkContext (COW):
```ruby
# Process batches of 1000 items each in separate processes
batch 1000
process_per_batch(max: 4) do
  consumer :save_to_db do |batch|
    # Fork happens here, process entire batch, exit
    DB.bulk_insert(batch)
  end
end
```

### Use ProcessPoolContext (IPC):
```ruby
# 4 persistent workers processing items continuously
processes(4) do
  processor :parse do |item|
    # Workers stay alive, process items one by one via IPC
    JSON.parse(item)
  end
end
```

## Implementation Status

- ✅ `ForkContext` - COW fork (existing, works)
- ✅ `ProcessPoolContext` - IPC persistent workers (NEW)
- ✅ `InlineContext` - Direct execution (refactored in pipeline.rb)
- ✅ Factory method updated to distinguish `:fork` vs `:processes`
- 🔄 Testing needed for process pools

