# Minigun - Clean Implementation Summary

## What We Built

A **clean, from-scratch implementation** of the Minigun gem in `lib_new/` that follows the producer→accumulator→consumer(fork) pattern from your original publishers.

## Files Created

```
lib_new/
├── minigun.rb              # Main entry point
├── minigun/
│   ├── version.rb          # Version constant
│   ├── task.rb             # Core Task class (270 lines)
│   └── dsl.rb              # Simple DSL module (90 lines)
└── README.md               # Documentation

test_new_minigun.rb         # Working example/test
```

## Key Features ✅

### 1. Producer → Accumulator → Consumer Pattern
- **Producer**: Generates items, emits to queue
- **Processor** (optional): Transforms items inline
- **Accumulator**: Batches items until thresholds
- **Consumer**: Processes in parallel (fork or threads)

### 2. Simple DSL
```ruby
class MyTask
  include Minigun::DSL

  max_threads 10
  max_processes 4

  pipeline do
    producer :generate { emit(item) }
    processor :transform { |item| emit(modified) }
    consumer :process { |item| handle(item) }
  end
end
```

### 3. Lifecycle Hooks
- `before_run` - Before pipeline starts
- `after_run` - After pipeline completes
- `before_fork` - Before forking (disconnect DB)
- `after_fork` - In child after fork (reconnect DB)

### 4. Thread Safety
- `Concurrent::AtomicFixnum` for counters
- `SizedQueue` for producer→accumulator
- Thread pools from `concurrent-ruby`

### 5. Platform Support
- **Unix**: Uses `fork()` for process parallelism
- **Windows**: Falls back to threads (no fork)

## How It Works

### Architecture

```
┌─────────────┐
│  Producer   │ → generates items
│   Thread    │
└──────┬──────┘
       │ SizedQueue
       ↓
┌─────────────┐
│ Accumulator │ → batches by type
│   Thread    │ → checks thresholds
└──────┬──────┘
       │ fork() or threads
       ↓
┌─────────────┐
│  Consumer   │ → processes with
│  (Forked)   │   thread pool
└─────────────┘
```

### Execution Flow

1. **Start Pipeline**
   - Run `before_run` hooks
   - Create queue (`SizedQueue`)
   - Start producer thread
   - Start accumulator thread

2. **Producer**
   - Executes producer block
   - User calls `emit(item)` in block
   - Items go to queue
   - Sends `:END_OF_QUEUE` when done

3. **Accumulator**
   - Pulls from queue
   - Optionally runs processors
   - Groups by `item.class.name`
   - Checks thresholds every 100 items:
     - Single queue ≥ 2000 items → fork
     - Total ≥ 4000 items → fork all

4. **Consumer**
   - On Unix: `fork()` creates child process
   - On Windows: runs in main process
   - Creates thread pool (`max_threads`)
   - Processes items concurrently
   - Waits for completion

5. **Cleanup**
   - Wait for all consumers
   - Run `after_run` hooks
   - Return accumulated count

## Configuration

```ruby
max_threads 10        # Threads per consumer
max_processes 4       # Max concurrent forks
max_retries 3         # (future feature)

# Internal (can be overridden)
accumulator_max_single: 2000      # Single queue threshold
accumulator_max_all: 4000         # Total threshold
accumulator_check_interval: 100   # Check every N items
```

## Example Output

```
I, INFO -- : Starting Minigun pipeline
=== Starting Pipeline ===
I, INFO -- : [Producer] Starting
Producing 20 items...
I, INFO -- : [Accumulator] Starting
I, INFO -- : [Producer] Done. Produced 20 items
I, INFO -- : [Consumer] Processing 20 items (no fork)
[Consumer:1234] Processing: 2
[Consumer:1234] Processing: 4
...
I, INFO -- : [Consumer] Processed 20 items
I, INFO -- : [Accumulator] Done. Accumulated 20 items
I, INFO -- : Finished in 0.55s
I, INFO -- : Produced: 20, Accumulated: 20
=== Pipeline Complete ===
```

## Comparison to Original Publisher

### Original (`publisher_base.rb` - 514 lines)
```ruby
class MyPublisher < PublisherBase
  def default_models
    ['Customer', 'Order']
  end

  def consume_object(object)
    # process object
  end

  private

  def produce_model(model, range)
    # fetch IDs
  end
end

publisher = MyPublisher.new(
  start_time: 1.hour.ago,
  max_processes: 4
)
publisher.perform
```

### New Minigun (`lib_new/` - 360 lines total)
```ruby
class MyPublisher
  include Minigun::DSL

  max_processes 4

  pipeline do
    producer :fetch do
      Customer.find_each { |c| emit(c) }
      Order.find_each { |o| emit(o) }
    end

    consumer :process do |object|
      # process object
    end
  end
end

MyPublisher.new.run
```

## Next Steps

To fully replace the original publishers:

1. **Add Queue-based Routing** (for priority lanes)
2. **Add Model-based Scoping** (time ranges, franchises)
3. **Add Retry Logic** (with exponential backoff)
4. **Add Instrumentation** (stats, monitoring)
5. **Port All Publishers** to use new gem

## Testing

```bash
ruby test_new_minigun.rb
```

Output shows:
- ✅ Producer generates items
- ✅ Processor transforms them
- ✅ Consumer processes in parallel
- ✅ Hooks execute at right times
- ✅ Thread-safe counters work
- ✅ Windows fallback works

## Why This is Better

1. **Simpler**: 360 lines vs 514 lines for base class alone
2. **Cleaner DSL**: More intuitive, less boilerplate
3. **Testable**: Easy to mock and test each stage
4. **Extensible**: Easy to add features
5. **Modern**: Uses `concurrent-ruby`, atomic operations
6. **Cross-platform**: Works on Windows with fallback

## Status

✅ **WORKING** - Core pattern implemented and tested
- Producer thread ✅
- Accumulator with thresholds ✅
- Consumer with fork/thread fallback ✅
- Lifecycle hooks ✅
- Configuration ✅
- Simple DSL ✅

Ready to:
- Replace `lib/` with `lib_new/`
- Port original publishers
- Add remaining features as needed

