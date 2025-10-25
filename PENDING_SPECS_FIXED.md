# All Pending Specs Fixed ✅

## Summary

Fixed all 4 pending specs by implementing proper multi-source pipeline support and nested-to-multi pipeline promotion.

## Issues Fixed

### 1. Pipeline-level `from:` keyword (3 tests)

**Problem**: When defining pipelines with `from:` routing, the referenced source pipelines were sometimes nested stages rather than proper multi-pipelines, causing them not to execute.

**Solution**: Implemented `promote_nested_to_multi_pipeline` method in `lib/minigun/task.rb` that automatically converts nested pipeline stages to proper multi-pipelines when they're referenced in routing.

### 2. Diamond pattern in multi-pipelines (1 test)

**Problem**: When multiple pipelines fed into a single downstream pipeline (fan-in/diamond pattern), only one upstream source would connect properly. The issue was that `pipeline.input_queue = queue` would overwrite previous queues.

**Solution**: Refactored pipeline input handling to support multiple queues:
- Changed `@input_queue` (singular) to `@input_queues` (array)
- Updated setter to append instead of overwrite
- Modified input reading to spawn a thread for EACH input queue
- Maintained backward compatibility with `input_queue` reader

## Code Changes

### `lib/minigun/task.rb`
- Added `promote_nested_to_multi_pipeline(name)` method
- Updated `define_pipeline` to promote referenced pipelines

### `lib/minigun/pipeline.rb`
- Changed `@input_queue` → `@input_queues` (array)
- Updated `input_queue=` to append to array
- Added `input_queues` reader (returns array)
- Added `input_queue` reader (returns first, for backward compatibility)
- Added `add_input_queue(queue)` method
- Modified input queue reader thread to handle multiple queues
- Updated `build_dag_routing!` to check `@input_queues.any?`

## Test Results

**Before**: 236 examples, 0 failures, 4 pending
**After**: 236 examples, 0 failures, 0 pending ✅

All tests pass, including:
- ✅ Pipeline-level `from:` connecting pipelines in reverse
- ✅ Pipeline-level `from:` with multiple sources
- ✅ Mixing `to:` and `from:` at pipeline level
- ✅ Diamond patterns allowed in multi-pipelines

## Impact

This enables complex multi-pipeline routing patterns such as:

```ruby
# Diamond pattern with multiple sources
pipeline :source, to: [:left, :right] do
  producer :gen { emit(data) }
  consumer :fwd { |item| emit(item) }
end

pipeline :left, to: :merge do
  processor :transform { |item| emit(item + 10) }
  consumer :fwd { |item| emit(item) }
end

pipeline :right, to: :merge do
  processor :transform { |item| emit(item + 20) }
  consumer :fwd { |item| emit(item) }
end

pipeline :merge do
  consumer :collect { |item| results << item }
end
# Results: [11, 21] - Both paths work!
```

```ruby
# Multiple sources with from:
pipeline :a { ... }
pipeline :b { ... }

pipeline :collector, from: [:a, :b] do
  consumer :collect { |item| results << item }
end
# Collector receives items from BOTH :a and :b
```

## Backward Compatibility

All existing functionality preserved:
- Single input queue usage still works
- `input_queue` reader returns first queue
- All 236 existing tests pass

