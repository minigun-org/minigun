# Demand Implementation Assessment (Round 3)

**Date:** 2025-11-28
**Type:** Harden Assessment - Fresh Eyes

## Files Reviewed

- `lib/minigun/demand.rb` - Main module
- `lib/minigun/demand/tracker.rb` - Core counting logic
- `lib/minigun/demand/channel.rb` - Producer-consumer communication
- `lib/minigun/demand/registry.rb` - Channel management
- `lib/minigun/demand/aware_queues.rb` - Queue wrappers

## Issues Found

### 1. Inconsistent Error Messages in Tracker (TRIVIAL)

**Location:** `lib/minigun/demand/tracker.rb:36,58`

Line 36: `raise ArgumentError, 'min_demand must be positive' if min_demand < 0`
- Error says "positive" but condition checks `< 0` (should say "non-negative")

Line 58: `raise ArgumentError, 'count must be positive' if count < 0`
- Same issue: says "positive" but allows 0 (should say "non-negative")

**Fix:** Change wording to "non-negative" or change conditions to `<= 0`.

### 2. `@demand_timeout` Stored But Not Used in `wait_for_demand_if_needed` (MINOR)

**Location:** `lib/minigun/demand/aware_queues.rb:102`

`@demand_timeout` is stored in `AwareOutputQueue` but `wait_for_demand_if_needed` (the auto mode waiter) uses a hardcoded `timeout: 0.01`. The stored value is only used in the public `wait_for_demand` method (manual mode).

This is actually intentional: auto mode uses short timeouts for channel cycling, manual mode uses the configured timeout. But it's slightly confusing that the instance variable exists when auto mode ignores it.

**Verdict:** Keep as-is. The design is intentional - the short timeout in auto mode allows trying multiple channels quickly.

### 3. Constants Defined in Two Places (MINOR DUPLICATION)

**Location:**
- `lib/minigun/demand.rb:71-74` defines `DEFAULT_MIN_DEMAND = 500` and `DEFAULT_MAX_DEMAND = 1000`
- `lib/minigun/configuration.rb:19-21` also sets defaults to 500/1000

The constants in `demand.rb` are used by `Demand.create_channel` but the Configuration defaults are what's actually used everywhere else.

**Fix:** Remove `DEFAULT_MIN_DEMAND` and `DEFAULT_MAX_DEMAND` from `demand.rb` since `create_channel` should use `Minigun.default_min_demand` and `Minigun.default_max_demand`.

### 4. `Demand.create_channel` Factory Method Not Used (MINOR)

**Location:** `lib/minigun/demand.rb:83-90`

This factory method exists but is never used. The `Registry#register` method creates channels directly.

**Fix:** Either remove `Demand.create_channel` or have `Registry#register` use it.

### 5. Channel's `@items_consumed` Could Use Atomic (MINOR PERFORMANCE)

**Location:** `lib/minigun/demand/channel.rb:38,62,137-139`

`@items_consumed` uses a Mutex for thread safety. Since it's only incremented, could use `Concurrent::AtomicFixnum` for slightly better performance.

**Verdict:** Keep as-is. The overhead is negligible and adding a dependency for this isn't worth it.

## Recommended Refactors

### Fix #1: Remove Unused `Demand.create_channel` and Constants

The factory method and duplicate constants aren't used. Removing them cleans up the code.

```ruby
# In lib/minigun/demand.rb, remove lines 70-90:
# - DEFAULT_MIN_DEMAND constant
# - DEFAULT_MAX_DEMAND constant
# - create_channel method
```

### Fix #2: Fix Error Message Wording

Change "positive" to "non-negative" for conditions checking `< 0`:

```ruby
# tracker.rb:36
raise ArgumentError, 'min_demand must be non-negative' if min_demand < 0

# tracker.rb:58
raise ArgumentError, 'count must be non-negative' if count < 0
```

Or change conditions to be consistent with wording (check `<= 0` for "positive").

## Not Recommended

1. Using AtomicFixnum for `@items_consumed` - premature optimization
2. Changing timeout logic in `wait_for_demand_if_needed` - works correctly as designed
3. Major structural changes - the code is clean and well-organized

## Verdict

**Confidence: 95%+ slam-dunk**

Fix #1 removes unused code (clear win).
Fix #2 is minor wording fix for consistency.

Both are safe, low-risk changes.
