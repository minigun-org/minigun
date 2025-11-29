# Harden Ractor Implementation

**Date:** 2025-11-28 23:00
**Scope:** RactorPoolExecutor specific hardening

## Summary

Focused hardening pass on the RactorPoolExecutor implementation, improving code quality and adding missing functionality.

## Changes Applied

### 1. Removed Unused Parameter (executor.rb:834-835)

**Before:**
```ruby
worker = Ractor.new(stage_proc, result_port, i, name: "minigun-ractor-#{i}") do |proc, rport, _id|
```

**After:**
```ruby
worker = Ractor.new(stage_proc, result_port, name: "minigun-ractor-#{i}") do |proc, rport|
```

**Rationale:** The `_id` parameter was passed to the Ractor but never used inside the block. The worker name is already set via the `name:` keyword argument, making the `_id` redundant.

### 2. Added Stats Tracking (executor.rb:861-873, 906-908)

**Worker side (inside Ractor):**
- Added `start_time = Time.now` before processing
- Calculate `latency = Time.now - start_time` after processing
- Include latency in item_done message: `{ type: :item_done, latency: latency }`

**Collector side (main thread):**
- Record latency when receiving item_done: `@stage_ctx.stage_stats&.record_latency(msg[:latency])`

**Rationale:** RactorPoolExecutor was the only executor not tracking per-item latency. This brings it in line with other executors (FiberPoolExecutor, CowForkPoolExecutor, etc.) for consistent HUD monitoring and performance analysis.

## Items Reviewed But Not Changed

### @pool_timeout Storage

The `@pool_timeout` is stored but not directly used in RactorPoolExecutor's logic. However:
- It's passed to the fallback ThreadPoolExecutor
- Implementing timeout for Ractor work distribution would require complex coordination
- Keeping it maintains API consistency with other executors

**Decision:** Keep as-is for API consistency and fallback support.

### Duplicate Shareable Handling

There are two places that attempt to make blocks shareable:
1. `pipeline.rb:122-136` - Uses `Ractor.shareable_proc` at stage definition time
2. `executor.rb:812-828` - Uses `Ractor.make_shareable(block.dup)` at execution time

**Rationale for keeping both:**
- Pipeline.rb handles explicit `shareable: true` and `shareable_auto: true` options
- Executor.rb provides a fallback check if the block wasn't already made shareable
- The executor check is defensive - it first checks `Ractor.shareable?(block)` before trying to make it shareable
- Two-tier approach provides flexibility for different usage patterns

## Test Impact

All changes are backwards-compatible:
- Stats tracking is additive (uses safe navigation `&.`)
- Removed parameter was unused
- No API changes

## Risk Assessment

- **Low risk** - No behavioral changes for existing users
- **Benefit**: Better observability through stats tracking
- **Benefit**: Cleaner code with removed unused parameter
