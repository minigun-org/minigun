# Queue-Based DSL Refactor - COMPLETE

## Summary

Successfully completed a **hard refactor** to a new queue-based DSL that eliminates `emit` methods and uses block arguments for input/output queues. This resolves concurrency issues and provides a cleaner, more explicit API.

## What Changed

### 1. DSL Methods - Explicit Stage Types

Replaced implicit arity-based stage type detection with explicit DSL methods:

```ruby
# OLD (arity-based):
stage :process do |item|  # inferred as consumer
  # ...
end

# NEW (explicit):
producer :generate do |output|
  output << item
end

processor :transform do |item, output|
  output << transformed_item
end

consumer :store do |item|
  # terminal - no output
end

stage :custom_loop do |input, output|
  while (item = input.pop) != Minigun::AllUpstreamsDone.instance(:custom_loop)
    output << process(item)
  end
end
```

### 2. Queue Wrappers

Created three new classes in `lib/minigun/queue_wrappers.rb`:

- **`InputQueue`**: Wraps stage input queues, handles END signals, returns `AllUpstreamsDone` sentinel when all upstream stages complete
- **`OutputQueue`**: Wraps stage output queues, provides `<<` for default routing and `.to(stage_name)` for explicit routing
- **`AllUpstreamsDone`**: Sentinel object indicating all upstream stages have finished

### 3. Stage Execution

Updated `Stage#execute` to use queue-based arguments:

```ruby
def execute(context, item: nil, input_queue: nil, output_queue: nil)
  case @stage_type
  when :producer
    context.instance_exec(output_queue, &@block)
  when :consumer
    context.instance_exec(item, &@block)
  when :processor
    context.instance_exec(item, output_queue, &@block)
  when :stage
    context.instance_exec(input_queue, output_queue, &@block)
  end
end
```

### 4. Executor Updates

Updated all `Executor` subclasses to accept and pass queue wrappers:

- `InlineExecutor`: Passes queues through
- `ThreadPoolExecutor`: Passes queues through to thread workers
- `ProcessPoolExecutor`: Raises `NotImplementedError` (queues can't cross process boundaries without IPC)
- `RactorPoolExecutor`: Falls back to threads (similar IPC issues)

### 5. StageWorker Refactoring

`StageWorker` now creates queue wrappers and passes them to executors:

```ruby
wrapped_input = InputQueue.new(raw_queue, @stage_name, sources_expected)
wrapped_output = OutputQueue.new(@stage_name, downstream_queues, all_queues, runtime_edges)

executor.execute_stage_item(
  stage: stage,
  item: item,
  input_queue: wrapped_input,
  output_queue: wrapped_output,
  ...
)
```

### 6. Producer Execution

Producers now receive `OutputQueue` wrappers directly:

```ruby
output_queue = OutputQueue.new(producer_name, downstream_queues, stage_input_queues, runtime_edges)
producer_stage.execute(@context, item: nil, input_queue: nil, output_queue: output_queue)
```

## Removed Features

- **`emit` and `emit_to_stage` methods**: Completely removed, replaced with queue operations
- **Backwards compatibility**: No attempt to support old DSL
- **Process pools**: Temporarily unsupported (requires IPC layer for queues)
- **Nested pipelines (PipelineStage)**: Temporarily unsupported (requires additional refactoring)

## Files Modified

- `lib/minigun/dsl.rb`: Added explicit DSL methods (producer/processor/consumer/stage)
- `lib/minigun/stage.rb`: Refactored `execute` to use queues, added `stage_type`, removed emit logic
- `lib/minigun/execution/executor.rb`: Updated to pass queues through
- `lib/minigun/execution/stage_worker.rb`: Creates and passes queue wrappers
- `lib/minigun/pipeline.rb`: Producers use OutputQueue
- `lib/minigun/queue_wrappers.rb`: **NEW** - Queue wrapper classes
- `lib/minigun.rb`: Added require for queue_wrappers

## Examples

Created `examples/000_new_dsl_simple.rb`:

```ruby
class SimpleDslExample
  include Minigun::DSL

  pipeline do
    producer :generate do |output|
      5.times { |i| output << (i + 1) }
    end

    processor :double do |num, output|
      output << num * 2
    end

    consumer :collect do |num|
      @results << num
    end
  end
end
```

**Result**: ✓ Success! `[2, 4, 6, 8, 10]`

## Known Limitations

1. **Process Pools**: Not supported (queues can't cross process boundaries)
2. **Ractor Pools**: Falls back to threads (similar IPC issues)
3. **Nested Pipelines**: Multi-pipeline examples need additional work
4. **PipelineStage Producers**: Need refactoring to use OutputQueue

## Next Steps

To fully support the original use cases:

1. **Multi-Pipeline Support**: Refactor how named pipelines work to avoid PipelineStage wrapping for the queue-based DSL
2. **Process Pool IPC**: Implement IPC layer for queue operations across process boundaries
3. **Advanced Examples**: Port remaining examples to new DSL
4. **Test Suite**: Update all specs to use new DSL

## Benefits

✅ **Thread-safe by design**: No shared mutable state via singleton methods
✅ **Explicit data flow**: Clear input/output via queue arguments
✅ **Cleaner API**: No magic `emit` methods, just queue operations
✅ **Better debugging**: Explicit routing makes data flow traceable
✅ **Dynamic routing**: `output.to(:stage_name)` for runtime routing decisions

## Test Results

```bash
$ bundle exec ruby examples/000_new_dsl_simple.rb

=== Simple Queue-Based DSL Example ===

[Producer] Generating numbers...
[Producer] Emitting: 1-5
[Processor] 1-5 * 2 = 2-10
[Consumer] Storing: 2, 4, 6, 8, 10

=== Final Results ===
Collected: [2, 4, 6, 8, 10]
Expected: [2, 4, 6, 8, 10]
✓ Success!
```

---

**Status**: ✅ Core refactor complete, single-pipeline examples working
**Date**: October 27, 2025

