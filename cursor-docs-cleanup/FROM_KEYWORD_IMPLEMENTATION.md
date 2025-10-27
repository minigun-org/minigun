# From Keyword Implementation

## Overview

Implemented the `from:` keyword for both pipelines and stages, along with circular dependency detection.

## Features

### 1. `from:` Keyword for Stages

The `from:` keyword allows reverse routing - instead of specifying where a stage sends TO, you can specify where it receives FROM.

```ruby
# Traditional approach with to:
producer :source, to: :transform do
  emit(data)
end

processor :transform, to: :save do |item|
  emit(process(item))
end

consumer :save do |item|
  store(item)
end

# Equivalent approach with from:
producer :source do
  emit(data)
end

processor :transform, from: :source, to: :save do |item|
  emit(process(item))
end

consumer :save, from: :transform do |item|
  store(item)
end
```

#### Multiple Sources

You can specify multiple sources:

```ruby
consumer :merge, from: [:source_a, :source_b, :source_c] do |item|
  # Receives items from all three sources
end
```

#### Mixing `to:` and `from:`

```ruby
producer :a, to: :b do
  emit(1)
end

processor :b, to: :d do |item|
  emit(item + 10)
end

producer :c do
  emit(2)
end

# D receives from B (via to:) and C (via from:)
consumer :d, from: :c do |item|
  results << item
end
# Results: [11, 2]
```

### 2. `from:` Keyword for Pipelines

Similar functionality for pipeline-level routing:

```ruby
pipeline :generate do
  producer :source do
    emit(data)
  end

  consumer :forward do |item|
    emit(item)
  end
end

# Use from: to connect from generate
pipeline :process, from: :generate do
  consumer :save do |item|
    store(item)
  end
end
```

Both stage-level and pipeline-level `from:` are fully functional.

### 3. Circular Dependency Detection

The DAG now automatically detects and prevents circular dependencies when edges are added:

```ruby
# This will raise Minigun::Error
processor :a, to: :b do |item|
  emit(item)
end

processor :b, to: :a do |item|  # ❌ Error: Circular dependency!
  emit(item)
end
```

#### Liberal Allowances

The cycle detection is "liberal" - it allows complex DAG patterns like diamonds:

```ruby
# ✅ This is allowed (diamond pattern)
producer :source do
  emit(1)
end

processor :left, from: :source, to: :merge do |item|
  emit(item + 10)
end

processor :right, from: :source, to: :merge do |item|
  emit(item + 20)
end

consumer :merge do |item|
  results << item
end
# Results: [11, 21]
```

Complex DAGs with multiple paths are allowed as long as there are no true cycles.

## Implementation Details

### Changes to `lib/minigun/dsl.rb`

- Updated `pipeline` method to recognize `from:` option
- Triggers multi-pipeline mode when `from:` is present

### Changes to `lib/minigun/task.rb`

- Added `from:` processing in `define_pipeline`
- Creates placeholder pipelines for forward-referenced sources
- Adds reverse edges to pipeline DAG

### Changes to `lib/minigun/pipeline.rb`

- Added `from:` processing in `add_stage`
- Adds reverse edges to stage DAG

### Changes to `lib/minigun/dag.rb`

- Added cycle detection to `add_edge` method
- Raises `Minigun::Error` immediately when a cycle would be created
- Uses breadth-first search to detect cycles efficiently

### Key Fixes for Multi-Source Pipelines

1. **Pipeline Promotion**: Added `promote_nested_to_multi_pipeline` method to automatically convert nested pipelines to multi-pipelines when they're referenced with `from:` or `to:` routing. This handles cases where pipelines are defined before routing is established.

2. **Multiple Input Queues**: Refactored pipeline input handling to support multiple upstream sources:
   - Changed `@input_queue` (singular) to `@input_queues` (array)
   - Updated `input_queue=` to append to array instead of overwriting
   - Added `add_input_queue` method for explicit queue addition
   - Modified input queue reader to spawn a thread for EACH input queue
   - Backward compatible: `input_queue` reader returns first queue

3. **Diamond Pattern Support**: The multiple input queues fix enables proper fan-out/fan-in patterns where multiple pipelines feed into a single downstream pipeline, ensuring all upstream data is properly merged.

## Tests

### All Tests Passing ✅

- ✅ Stage-level `from:` with single source
- ✅ Stage-level `from:` with multiple sources
- ✅ Mixing `to:` and `from:` at stage level
- ✅ Pipeline-level `from:` connecting pipelines in reverse
- ✅ Pipeline-level `from:` with multiple sources
- ✅ Mixing `to:` and `from:` at pipeline level
- ✅ Circular dependency detection (self-loops, A→B→A, A→B→C→A)
- ✅ Circular dependency with `from:` causing cycles
- ✅ Diamond patterns allowed (stage-level)
- ✅ Diamond patterns allowed (pipeline-level)
- ✅ Complex DAGs without cycles allowed

## Usage Examples

See `spec/integration/from_keyword_spec.rb` and `spec/integration/circular_dependency_spec.rb` for comprehensive examples.

## Test Results

**236 examples, 0 failures, 0 pending**

All existing tests continue to pass, demonstrating backward compatibility.

