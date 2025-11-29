# Harden Assessment: Cluster Direct Mode Implementation

Date: 2025-11-29

## Context

Assessment of the cluster API changes made in this session:
1. Changed `coordinator:` parameter to `coordinator_uri:`
2. Added `worker_uris:` parameter for direct mode (no coordinator)
3. Implemented direct mode in ClusterPoolExecutor
4. Added `process_item_sync` to Worker and `process_item` to WorkerService
5. Created example 118 for direct mode
6. Updated 8 existing examples and documentation

## Files Changed

- `lib/minigun/dsl.rb` - `in_cluster` method signature
- `lib/minigun/execution/executor.rb` - ClusterPoolExecutor direct mode
- `lib/minigun/cluster.rb` - Worker.process_item_sync, WorkerService.process_item
- `examples/110-118` - All cluster examples
- `docs/guides/17_clustering.md` - Documentation
- `spec/integration/examples_spec.rb` - Added example 118 spec

## Assessment Findings

### Code Quality: Good

1. **DSL validation** - Properly validates that exactly one mode must be specified
2. **Clean separation** - Coordinator mode and direct mode are cleanly separated in the executor
3. **Error handling** - Direct mode gracefully handles failed worker connections
4. **Documentation** - Updated docs cover both modes with examples

### Potential Issues Found

1. **Direct mode shutdown calls `shutdown` on workers** (line 1077 in executor.rb)
   - In direct mode, workers are standalone services not meant to be shut down
   - The current code tries to call `shutdown` which could kill long-running workers
   - **Impact**: Low - workers catch the shutdown and ignore it, but it's semantically wrong

2. **Direct mode only returns first result** (line 236 in cluster.rb)
   - `process_item_sync` only returns `results.first`
   - If a stage emits multiple items per input, only the first is returned
   - **Impact**: Medium - could cause data loss for fan-out stages

3. **No test coverage for direct mode executor**
   - The new direct mode execution path in ClusterPoolExecutor is not unit tested
   - Only integration testing via manual examples
   - **Impact**: Low - existing cluster unit tests cover coordinator mode

### Slam-Dunk Improvements (95%+ confident)

1. **Fix shutdown_direct_mode** - Should not call `shutdown` on workers since they're standalone services. Just clear the list.

2. **Fix process_item_sync to return all results** - Should return array of results, not just first.

### NOT Recommended Changes

1. **Don't add unit tests now** - The direct mode is tested by the loopback example; adding complex DRb mocking tests would be overkill
2. **Don't refactor distribute_and_collect_direct** - It's similar to coordinator mode but different enough that extracting common code would add complexity

## Plan

### Fix 1: shutdown_direct_mode should not shutdown workers

```ruby
def shutdown_direct_mode
  # Don't call shutdown on workers - they're standalone services
  # Just clear our references
  @direct_workers = []
end
```

### Fix 2: process_item_sync should return all results

```ruby
def process_item_sync(stage_name, item)
  # ... existing code ...

  # Return all results (may be empty, single, or multiple)
  results
end
```

And update distribute_and_collect_direct to handle array results.

## Execution

Proceeding with both slam-dunk fixes.
