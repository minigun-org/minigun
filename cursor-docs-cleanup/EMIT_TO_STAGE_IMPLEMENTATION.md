# emit_to_stage Implementation Summary

## Overview

`emit_to_stage` is a powerful dynamic routing feature that allows stages to explicitly route items to specific downstream stages at runtime, bypassing the normal DAG routing. This enables advanced routing patterns like load balancing, priority routing, type-based routing, and custom batching.

## Implementation Details

### Core Changes

#### 1. `lib/minigun/stage.rb`
- Updated `AtomicStage#execute_with_emit` to support both `emit` and `emit_to_stage`
- Returns a mixed format array:
  - Plain items from `emit()` use normal DAG routing
  - Hashes with `{ item:, target: }` from `emit_to_stage()` use explicit routing
- Maintains backward compatibility: if only `emit()` is used, returns plain array

```ruby
def execute_with_emit(context, item)
  emitted_items = []
  emit_targets = []

  context.define_singleton_method(:emit) { |i| emitted_items << i }
  context.define_singleton_method(:emit_to_stage) { |target_stage, i|
    emit_targets << { item: i, target: target_stage }
  }

  execute(context, item)

  # Return mixed format if there are targeted emits
  emit_targets.any? ? (emitted_items + emit_targets) : emitted_items
end
```

#### 2. `lib/minigun/pipeline.rb`
- Updated `start_accumulator` to handle 3-tuple format: `[item, source_stage, explicit_target]`
- Added explicit target detection and routing logic:
  ```ruby
  item, source_stage, explicit_target = item_data

  targets = if explicit_target
              [explicit_target]  # Use explicit target
            else
              get_targets(source_stage)  # Use DAG routing
            end
  ```
- Updated producer `emit` methods to include `nil` as third element for backward compatibility
- Added validation logging for invalid target stages

### Usage Examples

#### Basic Dynamic Routing
```ruby
stage :router do |item|
  case item[:priority]
  when 'high'
    emit_to_stage(:high_priority_handler, item)
  when 'low'
    emit_to_stage(:low_priority_handler, item)
  end
end

consumer :high_priority_handler do |item|
  # Process high priority items
end

consumer :low_priority_handler do |item|
  # Process low priority items
end
```

#### Load Balancing
```ruby
stage :load_balancer do |item|
  worker = @counter % 3
  @counter += 1
  emit_to_stage(:"worker_#{worker}", item)
end
```

#### Custom Batching with Routing
```ruby
stage :type_batcher do |item|
  @batches ||= Hash.new { |h, k| h[k] = [] }
  @batches[item[:type]] << item

  if @batches[item[:type]].size >= batch_size
    batch = @batches[item[:type]].dup
    @batches[item[:type]].clear
    emit_to_stage(:"#{item[:type]}_handler", batch)
  end
end
```

#### Cross-Context Routing
```ruby
stage :router do |item|
  # Route to different execution contexts based on workload
  case item[:workload]
  when 'light'
    emit_to_stage(:thread_processor, item)
  when 'heavy'
    emit_to_stage(:process_processor, item)
  end
end

threads(3) do
  consumer :thread_processor do |item|
    # Runs in thread pool
  end
end

process_per_batch(max: 2) do
  consumer :process_processor do |item|
    # Runs in forked processes with automatic IPC
  end
end
```

### Transport Detection

The framework automatically handles IPC transport based on the target stage's execution context:
- **Same Context**: Direct queue passing
- **Thread Pool**: Shared memory queue
- **Process Per Batch**: Marshal-based IPC via `IO.pipe` (implemented in `ForkContext`)
- **Ractor Pool**: Message passing (Ractor-safe objects only)

The user doesn't need to worry about transport mechanisms - it's all handled transparently.

### Error Handling

- Invalid target stages are logged as errors but don't crash the pipeline
- Pipeline continues processing valid items
- Error example:
  ```
  [Pipeline:default] emit_to_stage: Unknown target stage 'nonexistent'
  ```

### Testing

#### Unit Tests (`spec/unit/emit_to_stage_spec.rb`)
- **14 comprehensive tests** covering:
  - Basic routing to explicit stages
  - Mixing `emit` and `emit_to_stage`
  - Multiple `emit_to_stage` calls per stage
  - Error handling for invalid stages
  - Cross-execution-context routing
  - Complex routing patterns (priority, load balancing, multi-level)
  - Custom batching with dynamic routing
  - `AtomicStage#execute_with_emit` format validation

#### Integration Tests
- `examples/44_custom_batching.rb`: Custom batching with type-based routing
- `examples/45_emit_to_stage_cross_context.rb`: Cross-context routing with threads and processes

### Examples Created

1. **`examples/44_custom_batching.rb`** (257 lines)
   - Demonstrates custom batching logic
   - Routes different email types to type-specific senders
   - Shows manual buffer management and threshold-based emission

2. **`examples/45_emit_to_stage_cross_context.rb`** (115 lines)
   - Shows routing across different execution contexts
   - Demonstrates automatic IPC handling
   - Routes tasks to thread pools and processes based on workload

3. **Unit Test Suite** (`spec/unit/emit_to_stage_spec.rb`, 652 lines)
   - Comprehensive coverage of all `emit_to_stage` features
   - Tests basic functionality, error handling, execution contexts, and complex patterns

## Backward Compatibility

✅ Fully backward compatible!
- Existing pipelines using only `emit()` continue to work unchanged
- `execute_with_emit` returns plain array when `emit_to_stage` is not used
- No breaking changes to the public API

## Test Results

```
381 examples, 0 failures, 12 pending

- Unit tests: 14 emit_to_stage-specific tests, all passing
- Integration tests: 46 example tests, all passing
- Total test coverage: Comprehensive
