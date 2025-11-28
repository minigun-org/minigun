# Demand Implementation Assessment

**Date:** 2025-11-28
**Type:** Harden Assessment

## Issues Found

### 1. DRY Violation: Duplicated `wait_for_demand_if_needed` (MODERATE)

**Location:** `lib/minigun/demand/aware_queues.rb`

Both `AwareOutputQueue` (lines 207-222) and `AwareTargetedOutputQueue` (lines 261-271) have nearly identical `wait_for_demand_if_needed` methods.

**Fix:** Extract to a shared module or use delegation.

### 2. Unused `@target_stage` Instance Variable (MINOR)

**Location:** `lib/minigun/demand/aware_queues.rb:239`

`@target_stage` is stored but never used in `AwareTargetedOutputQueue`.

**Fix:** Remove or use it.

### 3. Unused `@runtime_edges` Instance Variable (MINOR)

**Location:** `lib/minigun/demand/aware_queues.rb:241`

`@runtime_edges` is stored in `AwareTargetedOutputQueue` but never used (the edge tracking happens in the parent `AwareOutputQueue.to()` method).

**Fix:** Remove from constructor parameters.

### 4. Unused `MODES` Constant (MINOR)

**Location:** `lib/minigun/demand/aware_queues.rb:93`

`MODES = %i[auto manual disabled].freeze` is defined but never used for validation.

**Fix:** Either validate `demand_mode` against `MODES` or remove the constant.

### 5. Potential Busy-Loop in `wait_for_demand_if_needed` (MINOR PERFORMANCE)

**Location:** `lib/minigun/demand/aware_queues.rb:212-218`

The loop tries each channel with 0.01s timeout, then sleeps 0.001s. With many channels, this could be inefficient.

**Current behavior is acceptable** for initial implementation - sophisticated strategies (like priority-based or round-robin demand distribution) can be added later.

## Recommended Refactors (Slam-dunk improvements)

### 1. Extract Shared Demand Waiting Logic

Create a helper module to DRY up the duplicated wait logic:

```ruby
module DemandWaiter
  def wait_for_demand_if_needed
    return if @demand_mode != :auto || @demand_channels.empty?

    loop do
      @demand_channels.each do |channel|
        return if channel.wait_for_demand(1, timeout: 0.01)
      end

      sleep(0.001)
      return if @demand_channels.all?(&:closed?)
    end
  end
end
```

### 2. Remove Unused Variables

Remove `@target_stage` and `@runtime_edges` from `AwareTargetedOutputQueue`.

### 3. Validate demand_mode

Either use `MODES` constant for validation or remove it.

## Not Recommended (Over-engineering)

1. Complex demand distribution strategies - wait for actual use cases
2. Metrics recording in wait loops - can add later when HUD integration needed
3. Configurable sleep intervals - premature optimization

## Verdict

**Confidence: 95%+ slam-dunk improvement**

The refactors are straightforward code cleanup that:
- Reduce code duplication
- Remove dead code
- Maintain identical behavior

Proceeding with automatic fixes.
