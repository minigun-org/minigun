# Cluster Deep Harden Assessment

**Date**: 2025-11-29 11:25
**Context**: Deep assessment of cluster module implementation

## Code Review Summary

### Files Analyzed
- `lib/minigun/cluster.rb` - Coordinator, Worker, WorkerService, Discovery
- `lib/minigun/cluster/delivery_tracker.rb` - In-flight item tracking
- `lib/minigun/cluster/distributor.rb` - AtMostOnce/AtLeastOnce distributors
- `lib/minigun/execution/executor.rb` - ClusterPoolExecutor
- `spec/unit/cluster_jepsen_spec.rb` - Jepsen-style tests

## Issues Found

### 1. CRITICAL: Naming Collision - Two DeliveryTracker Classes

**Problem**: There are TWO classes named `DeliveryTracker`:
- Production: `Minigun::Cluster::DeliveryTracker` in `lib/minigun/cluster/delivery_tracker.rb`
- Test: Anonymous `DeliveryTracker` in `spec/unit/cluster_jepsen_spec.rb` (lines 113-157)

These have completely different purposes:
- Production: Tracks in-flight items for at-least-once retry
- Test: Tracks sent/received items for verification

**Risk**: Confusing, potential for accidental reference errors in tests.

**Fix**: Rename test class to `TestDeliveryVerifier` or similar.

### 2. Missing Unit Tests for Production DeliveryTracker

**Problem**: `Minigun::Cluster::DeliveryTracker` has NO unit tests. It's only exercised indirectly through integration tests.

**Risk**: Bugs in edge cases (concurrent access, retry queue, completion tracking) may go undetected.

**Fix**: Add unit tests for:
- Thread-safety of `track`, `complete`, `fail`
- Retry queue behavior
- Duplicate completion detection
- `all_complete?` logic

### 3. Coordinator Mode Doesn't Use Distributors

**Problem**: `distribute_and_collect_coordinator` (executor.rb:1112-1173) has inline at-most-once logic instead of using the Distributor abstraction.

**Impact**:
- Coordinator mode is always at-most-once (no retry support)
- Code duplication between coordinator mode and `AtMostOnceDistributor`

**Recommendation**: Either:
- Document that coordinator mode is at-most-once only (acceptable)
- OR create a CoordinatorDistributor that wraps the coordinator (more work, less value)

**Decision**: Document it - coordinator mode is legacy pattern, direct mode is preferred.

### 4. DRY Opportunity: Result Handling Pattern

Both distributors and coordinator mode have similar collector thread patterns:
```ruby
loop do
  break if done_condition
  begin
    result = queue.pop(true)
    # handle result
    # decrement counter and signal
  rescue ThreadError
    sleep 0.01
  end
end
```

**Recommendation**: Could extract a `ResultCollector` helper, but complexity may not be worth it for ~30 lines.

**Decision**: Leave as-is - the variations are enough that extraction adds complexity without clear benefit.

### 5. Unused Stats Methods in DeliveryTracker

**Problem**: `in_flight_count`, `completed_count`, and `stats` methods are defined but never called.

**Recommendation**:
- Keep them - they're useful for debugging/monitoring
- Add tests for them to ensure they work

## Slam-Dunk Improvements

### 1. Rename Test DeliveryTracker (95% confidence)
Rename the test helper class to avoid confusion:
- `DeliveryTracker` → `TestDeliveryVerifier`

### 2. Add Unit Tests for Production DeliveryTracker (95% confidence)
Add focused tests for the delivery tracker class covering:
- Basic tracking
- Completion and duplicate detection
- Failure and retry
- Thread safety

## Action Plan

1. Rename test class `DeliveryTracker` → `TestDeliveryVerifier` in cluster_jepsen_spec.rb
2. Add unit tests for `Minigun::Cluster::DeliveryTracker`
3. Run tests to verify

These are clear improvements that add test coverage and reduce confusion.
