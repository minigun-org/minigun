# Time-Based Batch Flushing Implementation

## Summary

Implemented time-based batch flushing for the `BatchStage` class. Previously, batches were only flushed when `max_size` was reached. Now batches can also be flushed when `max_wait` time expires, enabling time-sensitive batch processing scenarios.

## Changes

### Core Implementation (`lib/minigun/stage.rb`)

`BatchStage` now supports two flushing triggers:

1. **Size-based** (existing): Flush when `max_size` items are collected
2. **Time-based** (new): Flush when `max_wait` seconds have elapsed since last flush

Key implementation details:
- When `max_wait` is nil (default), uses original size-only batching logic
- When `max_wait` is set, starts a background timer thread that periodically checks for time-based flushes
- Timer thread sleeps for `max_wait / 4.0` seconds between checks for responsiveness
- Thread-safe buffer access via existing mutex
- Timer thread is properly cleaned up when stage completes
- Extracted common `emit_batch` method for DRY code

### DSL Documentation (`lib/minigun/dsl.rb`)

Updated the `batch` DSL method documentation to clearly explain:
- Both `max_size` and `max_wait` options
- How they interact (flush on whichever comes first)
- Examples for various use cases

### Example Update (`examples/45_timed_batch_stage.rb`)

Simplified the example from using a custom `TimedBatchStage` class to using the built-in `max_wait` option:

```ruby
# Before: Custom stage class with manual timer logic
custom_stage TimedBatchStage, :batch, batch_size: 5, timeout: 0.3

# After: Built-in max_wait option
batch :batcher, max_size: 5, max_wait: 0.3
```

### New Tests (`spec/integration/timed_batch_spec.rb`)

Added comprehensive integration tests:
- Size-based batching (existing behavior)
- Time-based batching verification
- Size threshold still triggers immediate flush
- Mixed size and time triggering
- Shorthand syntax with max_wait
- Batch processing block with max_wait

### Unit Tests (`spec/minigun/stage_spec.rb`)

Extended `BatchStage` specs to verify:
- Default max_size (100)
- Default max_wait (nil)
- Custom max_size configuration
- Custom max_wait configuration
- Combined max_size and max_wait

## Usage Examples

```ruby
# Size-only batching (original behavior)
batch 10

# Time-based with size limit
batch :batcher, max_size: 50, max_wait: 2.0

# Primarily time-based (large size threshold)
batch :batcher, max_wait: 5.0

# With processing block
batch :writer, max_size: 100, max_wait: 5.0 do |batch, output|
  BulkWriter.insert(batch)
  output << batch.size
end
```

## Design Decisions

1. **Timer thread vs polling**: Chose background timer thread to avoid modifying `InputQueue.pop` behavior and maintain compatibility with demand-based queues

2. **Timer frequency**: Check every `max_wait / 4.0` seconds for reasonable responsiveness without excessive CPU usage

3. **Backwards compatible**: No changes to existing behavior when `max_wait` is nil

4. **Thread cleanup**: Timer thread is killed and joined on stage completion to prevent leaks

## Test Results

- Unit tests: 26 examples, 0 failures
- Integration tests: 6 examples, 0 failures
- All minigun specs: 239 examples, 0 failures
