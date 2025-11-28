# Demand Implementation Assessment (Round 2)

**Date:** 2025-11-28
**Type:** Harden Assessment - Fresh Eyes

## Issues Found

### 1. Code Smell: `instance_variable_get` in `AwareOutputQueue#to` (MODERATE)

**Location:** `lib/minigun/demand/aware_queues.rb:127-129`

```ruby
target_stage = @inner.instance_variable_get(:@stage).pipeline.task.stage_registry.find(
  target, from_pipeline: @inner.instance_variable_get(:@stage).pipeline
)
```

Using `instance_variable_get` to access private state of the inner object is a code smell. This breaks encapsulation and creates tight coupling to internal implementation details.

**Fix:** Either:
- A) Add a public accessor to OutputQueue for stage lookup
- B) Pass the stage reference to AwareOutputQueue constructor
- C) Store stage reference directly in AwareOutputQueue

### 2. Unused `@stage_stats` in `AwareOutputQueue` (MINOR)

**Location:** `lib/minigun/demand/aware_queues.rb:102`

`@stage_stats` is stored but never used directly - it's passed to the inner OutputQueue which handles stats tracking.

**Fix:** Remove the redundant instance variable.

### 3. Channel's `@items_consumed` Tracking is Redundant (MINOR)

**Location:** `lib/minigun/demand/channel.rb:38,62,137-139`

Channel tracks `@items_consumed` with its own mutex, but this duplicates stats tracking that's already done by `stage_stats.increment_consumed` in the queue wrappers. The value is never used anywhere except `to_s`.

**Fix:** Either remove it (since it's only for debugging) or keep it but note it's for debugging only.

### 4. Inconsistent Error Messages (TRIVIAL)

**Location:** `lib/minigun/demand/tracker.rb:36,37,58,75,106`

Error messages say "count must be positive" but:
- Line 36: `min_demand < 0` - should say "non-negative"
- Line 58: `count < 0` - should say "non-negative"
- Lines 75,106: `count <= 0` - correctly says "positive"

**Fix:** Use consistent terminology (non-negative vs positive).

## Recommended Refactors

### Fix #1: Remove `instance_variable_get` - Store stage reference

Pass stage to AwareOutputQueue and use it directly:

```ruby
def initialize(stage, downstream_queues, runtime_edges, ...)
  @stage = stage  # Keep reference for lookup
  @inner = Minigun::OutputQueue.new(stage, downstream_queues, runtime_edges, stage_stats: stage_stats)
  ...
end

def to(target)
  ...
  target_stage = @stage.pipeline.task.stage_registry.find(target, from_pipeline: @stage.pipeline)
  ...
end
```

### Fix #2: Remove unused `@stage_stats`

Just don't store it - inner queue handles stats.

## Not Recommended

1. Removing `@items_consumed` from Channel - it's useful for debugging
2. Changing error message wording - low value change

## Verdict

**Confidence: 95%+ slam-dunk**

Fix #1 is the main improvement - removing `instance_variable_get` makes the code cleaner and less fragile.
