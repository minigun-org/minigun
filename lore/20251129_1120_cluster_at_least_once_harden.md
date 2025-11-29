# Cluster At-Least-Once Delivery - Harden Assessment

**Date**: 2025-11-29 11:20
**Context**: At-least-once delivery mode implementation for cluster execution

## Summary of Recent Changes

Implemented at-least-once delivery semantics for distributed cluster execution:

1. **New Files**:
   - `lib/minigun/cluster/delivery_tracker.rb` - Tracks in-flight items with monotonic sequence IDs
   - `lib/minigun/cluster/distributor.rb` - Base class + AtMostOnceDistributor + AtLeastOnceDistributor

2. **Modified Files**:
   - `lib/minigun/cluster.rb` - Added requires
   - `lib/minigun/execution/executor.rb` - Added delivery_mode/max_retries to ClusterPoolExecutor
   - `lib/minigun/dsl.rb` - Added delivery_mode/max_retries to in_cluster DSL
   - `lib/minigun/worker.rb` - Pass delivery options to executor
   - `spec/unit/cluster_jepsen_spec.rb` - Added 5 at-least-once tests

## Assessment

### Code Quality: Good

The implementation is well-structured:
- Clean class hierarchy (Distributor base → AtMostOnce/AtLeastOnce subclasses)
- Thread-safe DeliveryTracker with clear responsibilities
- Factory pattern for creating distributors
- Comprehensive tests covering retry, exhaustion, and duplicate scenarios

### Potential Issues Identified

1. **Minor: Duplicate result handling in AtMostOnceDistributor**
   - Line 70-76: The `:results` branch handles multiple results but `:error` branch doesn't record latency
   - Not a bug, but inconsistent with AtLeastOnceDistributor which handles differently

2. **Minor: Coordinator mode doesn't use Distributor classes**
   - `distribute_and_collect_coordinator` (lines 1112-1173) has its own inline implementation
   - Only direct mode uses the Distributor abstraction
   - This is intentional (coordinator mode has different architecture) but worth noting

3. **Minor: Unused method in DeliveryTracker**
   - `retries_pending?` method (lines 105-107) is defined but never called
   - Could be removed, or kept for future use

4. **Observation: @pool_timeout unused**
   - Line 974 shows `pool_timeout` is passed but not used (rubocop disabled lint)
   - Documented in options but not implemented

### Refactor Candidates

1. **DRY opportunity: Collector thread pattern**
   - Both `AtMostOnceDistributor` and `AtLeastOnceDistributor` have very similar collector loops
   - Could extract to base class, but complexity may not be worth it (~30 lines each)
   - **Decision: Leave as-is** - the patterns differ enough that extraction would add complexity

2. **Consider: Move factory to Cluster module**
   - `Cluster.create_distributor` is already in the right place (Cluster module)
   - Good.

## Recommendations

### Slam-Dunk Improvements (95%+ confidence)

1. **Remove unused `retries_pending?` method** - Never called, adds dead code

2. **Add `@pool_timeout` to rubocop:disable comment** - Make the intent clearer that it's intentionally unused for now

### Deferred Improvements

1. **Coordinator mode delivery semantics** - Currently at-most-once only
   - Would require significant work to add at-least-once to coordinator mode
   - Direct mode is the recommended approach for new deployments
   - **Defer** - not urgent

2. **Timeout support** - `pool_timeout` option
   - Would add overall timeout for stage execution
   - **Defer** - can be added when needed

## Action Plan

Proceeding with slam-dunk improvements only:

1. Remove unused `retries_pending?` method from DeliveryTracker
2. Clean up rubocop disable comment

These are trivial, low-risk changes.
