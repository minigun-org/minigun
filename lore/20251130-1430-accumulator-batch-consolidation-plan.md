# Accumulator vs. Batch Consolidation Plan

**Status: COMPLETED** - All changes implemented and tests passing (1063 examples, 0 failures)

## Current State Analysis

### Terminology Confusion

The codebase has inconsistent naming between "accumulator" and "batch":

| Component | Current Name | Location |
|-----------|--------------|----------|
| Stage Class | `AccumulatorStage` | `lib/minigun/stage.rb:392` |
| DSL Method (full) | `accumulator()` | `lib/minigun/dsl.rb:542` |
| DSL Method (shorthand) | `batch()` | `lib/minigun/dsl.rb:417` |
| Stage Type Symbol | `:accumulator` | `lib/minigun/pipeline.rb:154` |
| Config Keys | `accumulator_max_single`, `accumulator_max_all`, `accumulator_check_interval` | `lib/minigun/task.rb:14-16` |
| HUD Type Detection | `:accumulator` | `lib/minigun/hud/stats_aggregator.rb:109`, `theme.rb:183` |
| Related Stages | `DebatchStage`, `RebatchStage` | `lib/minigun/stage.rb:471,497` |

### The Problem

1. **`batch()` is just a wrapper** - It simply calls `accumulator(nil, max_size: size)`
2. **DSL inconsistency** - We have `batch()`, `debatch()`, `rebatch()` but the main stage is called `accumulator`
3. **Mental model mismatch** - Users think in terms of batching, but internals use "accumulator"
4. **Config names** - All config uses `accumulator_*` prefix

### Related Stages Form a Family

```
batch()     → creates batches from stream (currently AccumulatorStage)
debatch()   → unpacks batches to individual items (DebatchStage)
rebatch()   → resizes batches (RebatchStage)
```

These three form a logical family and should share consistent naming.

## Recommendation: Rename to "Batch"

Rename from `accumulator` to `batch` throughout because:

1. **User-facing consistency** - `batch`, `debatch`, `rebatch` form a coherent family
2. **Simpler mental model** - "batching" is universally understood
3. **Existing shorthand preference** - The `batch()` DSL method already exists and is preferred

## Implementation Plan

### Phase 1: Rename Core Classes (Breaking)

1. **Rename `AccumulatorStage` → `BatchStage`**
   - File: `lib/minigun/stage.rb`
   - Update class name and all references

2. **Update module-level constant**
   - Ensure `Minigun::BatchStage` is exported

### Phase 2: Update DSL Methods

1. **Make `batch()` the primary method** (full-featured)
   - File: `lib/minigun/dsl.rb`
   - Change from shorthand to full implementation
   - Support all options: `max_size`, `max_wait` (future), block

2. **Deprecate `accumulator()` → alias to `batch()`**
   - Keep as backward-compat alias with deprecation warning
   - Remove in next major version

### Phase 3: Update Pipeline Integration

1. **Change stage type symbol** `:accumulator` → `:batch`
   - File: `lib/minigun/pipeline.rb:154`
   - Update case statement

2. **Update HUD stage type detection**
   - File: `lib/minigun/hud/stats_aggregator.rb:109`
   - File: `lib/minigun/hud/theme.rb:183`

### Phase 4: Update Configuration Keys

1. **Rename config keys**
   - `accumulator_max_single` → `batch_max_single`
   - `accumulator_max_all` → `batch_max_all`
   - `accumulator_check_interval` → `batch_check_interval`
   - File: `lib/minigun/task.rb:14-16`

2. **Add backward-compat aliases** (optional)
   - Support old config keys with deprecation warning

### Phase 5: Update Examples & Documentation

1. **Update examples using `accumulator`**
   - `examples/29_demand_with_accumulator.rb` → rename to `29_demand_with_batch.rb`
   - `examples/110_fiber_batching.rb` - update DSL calls
   - All other examples using `accumulator` DSL

2. **Update documentation**
   - `docs/guides/03_stages.md`
   - `docs/recipes/batch_processing.md`

### Phase 6: Update Tests

1. **Update test files**
   - `spec/minigun/dsl_spec.rb`
   - `spec/unit/functional_dsl_spec.rb`
   - Any integration tests using accumulator

## New DSL Signature

```ruby
# Primary method (full-featured)
batch(name = nil, max_size: 100, max_wait: nil, &block)

# Examples:
batch(10)                              # Shorthand: batch items into groups of 10
batch(:my_batcher, max_size: 50)       # Named batch stage
batch(:writer, max_size: 100) do |batch, output|
  # Custom batch processing
  BulkWriter.insert(batch)
  output << batch.size  # Pass through count
end

# Deprecated alias (emit warning)
accumulator(...)  # "accumulator is deprecated, use batch instead"
```

## Files to Modify

| File | Changes |
|------|---------|
| `lib/minigun/stage.rb` | Rename `AccumulatorStage` → `BatchStage` |
| `lib/minigun/dsl.rb` | Make `batch()` primary, `accumulator()` deprecated alias |
| `lib/minigun/pipeline.rb` | Change `:accumulator` → `:batch` |
| `lib/minigun/task.rb` | Rename config keys |
| `lib/minigun/hud/stats_aggregator.rb` | Update type detection |
| `lib/minigun/hud/theme.rb` | Update type detection |
| `examples/29_demand_with_accumulator.rb` | Rename file and update code |
| `examples/110_fiber_batching.rb` | Update DSL calls |
| `docs/guides/03_stages.md` | Update documentation |
| `docs/recipes/batch_processing.md` | Update documentation |
| `spec/minigun/dsl_spec.rb` | Update tests |
| `spec/unit/functional_dsl_spec.rb` | Update tests |

## Backward Compatibility Strategy

### Option A: Hard Break (Recommended for Pre-1.0)
- Remove `accumulator` entirely
- Simple, clean codebase
- Users update immediately

### Option B: Soft Deprecation
- Keep `accumulator` as deprecated alias
- Emit deprecation warnings
- Remove in next major version

**Recommendation**: Option A if this is pre-1.0, Option B otherwise.

## Testing Checklist

- [ ] All existing accumulator tests pass with new `batch` name
- [ ] `batch()` shorthand works: `batch(10)`
- [ ] Named batch works: `batch(:name, max_size: 10)`
- [ ] Block form works: `batch(:name) { |batch, out| ... }`
- [ ] `debatch` still works with `batch` stages
- [ ] `rebatch` still works with `batch` stages
- [ ] HUD displays batch stages correctly
- [ ] Config keys work with new names
- [ ] All examples run successfully

## Estimated Scope

- **Files to modify**: ~12
- **Lines of code**: ~100-150 changed
- **Risk level**: Medium (touches core stage infrastructure)
- **Breaking change**: Yes (class rename, config keys)
