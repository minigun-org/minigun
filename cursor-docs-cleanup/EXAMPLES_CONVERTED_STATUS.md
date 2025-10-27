# Examples Conversion Status - Queue-Based DSL

## ✅ Completed

### All Examples Converted (48 files)
All example files have been batch-converted from `emit()` to the new queue-based DSL using `output <<` syntax.

**Conversion applied:**
- `producer :name do` → `producer :name do |output|`
- `processor :name do |item|` → `processor :name do |item, output|`
- `emit(x)` → `output << x`
- `emit_to_stage(:target, x)` → `output.to(:target) << x`

### Core Framework Updated
- ✅ `lib/minigun/stage.rb` - Queue-based execution
- ✅ `lib/minigun/dsl.rb` - Explicit DSL methods (producer, processor, consumer, stage)
- ✅ `lib/minigun/execution/executor.rb` - Queue wrapper support
- ✅ `lib/minigun/execution/stage_worker.rb` - Queue wrapper creation
- ✅ `lib/minigun/pipeline.rb` - Producer execution with OutputQueue
- ✅ `lib/minigun/queue_wrappers.rb` - InputQueue, OutputQueue, AllUpstreamsDone

### Working Examples
- ✅ `000_new_dsl_simple.rb` - Passes ✓
- ✅ `00_quick_start.rb` - Passes ✓
- ✅ `01_sequential_default.rb` - Passes ✓
- ✅ `02_diamond_pattern.rb` - Passes ✓
- ✅ `03_fan_out_pattern.rb` - Passes ✓
- ✅ `04_complex_routing.rb` - Passes ✓
- ✅ `13_configuration.rb` - Converted
- ✅ `14_large_dataset.rb` - Converted
- ✅ `15_simple_etl.rb` - Passes ✓
- ✅ `11_hooks_example.rb` - Converted

## ⚠️ Test Suite Status

**Current: 390 examples, 134 failures, 6 pending**

### Categories of Failures

1. **Tests Using Old API (needs update)**: ~80 failures
   - Tests calling `emit()` directly
   - Tests expecting `execute_with_emit` method
   - Tests using old arity-based stage detection

2. **PipelineStage Not Supported**: ~30 failures
   - Multi-pipeline examples need PipelineStage refactoring
   - Currently raises `NotImplementedError`

3. **Process Pools Not Supported**: ~6 pending
   - Queues can't cross process boundaries
   - Need IPC layer implementation

4. **Missing Stage Methods**: ~10 failures
   - `to_h` method removed (tests expect it)
   - `[]` accessor method removed (tests expect it)

5. **Stage Worker Test Stubs**: ~2 failures
   - Fixed: Added `stage_with_loop?` to stage double

## 🎯 Next Steps to Pass All Tests

### 1. Update Unit Tests for New DSL
Files to update:
- `spec/minigun/stage_spec.rb` - Update to use new DSL methods
- `spec/minigun/pipeline_spec.rb` - Update stage creation
- `spec/minigun/task_spec.rb` - Update stage definitions
- `spec/unit/emit_to_stage_spec.rb` - Rewrite for `output.to(:stage)` syntax
- `spec/unit/emit_to_stage_v2_spec.rb` - Rewrite or delete
- `spec/unit/inheritance_spec.rb` - Update stage blocks
- `spec/unit/stage_hooks_spec.rb` - Update with new DSL
- `spec/unit/stage_hooks_advanced_spec.rb` - Update with new DSL

### 2. Update Integration Tests
Files to update:
- `spec/integration/multiple_producers_spec.rb` - Use `producer do |output|`
- `spec/integration/mixed_pipeline_stage_routing_spec.rb` - Update or skip PipelineStage tests
- `spec/integration/from_keyword_spec.rb` - Update stage definitions
- `spec/integration/circular_dependency_spec.rb` - Update with new DSL
- `spec/integration/errors_spec.rb` - Update stage blocks
- `spec/integration/isolated_pipelines_spec.rb` - Update stage definitions

### 3. Example Integration Tests
- `spec/integration/examples_spec.rb` - Already passes for converted simple examples
- Multi-pipeline examples will fail until PipelineStage is supported

### 4. Add Missing Stage Methods (for test compatibility)
Add back to `Stage` class:
```ruby
def to_h
  { name: @name, options: @options }
end

def [](key)
  case key
  when :name then @name
  when :options then @options
  else nil
  end
end
```

For `AtomicStage`:
```ruby
def to_h
  super.merge(block: @block, stage_type: @stage_type)
end

def [](key)
  case key
  when :block then @block
  when :stage_type then @stage_type
  else super
  end
end
```

## 📋 Test Update Strategy

### Replace Old Pattern:
```ruby
pipeline.add_stage(:producer, :fetch) { emit(data) }
pipeline.add_stage(:processor, :transform) { |item| emit(item * 2) }
```

### With New Pattern:
```ruby
pipeline.add_stage(:producer, :fetch) { |output| output << data }
pipeline.add_stage(:processor, :transform) { |item, output| output << item * 2 }
```

### For emit_to_stage Tests:
```ruby
# Old
emit_to_stage(:target, item)

# New
output.to(:target) << item
```

## 🚀 Benefits of New DSL

✅ **Thread-safe by design** - No shared singleton methods
✅ **Explicit data flow** - Clear input/output via queue arguments
✅ **No magic** - Direct queue operations instead of `emit`
✅ **Dynamic routing** - `output.to(:stage)` for runtime decisions
✅ **Better debugging** - Explicit queue routing is traceable

## 📝 Notes

- **No Backwards Compatibility**: This is a hard refactor, old `emit` API is GONE
- **Process Pools**: Will remain unsupported until IPC layer is implemented
- **PipelineStage**: Needs separate refactoring effort
- **Test Suite**: Focus on updating tests to new DSL, not maintaining old API

---

**Status**: All examples converted ✓ | Test suite needs updates for new DSL
**Date**: October 27, 2025

