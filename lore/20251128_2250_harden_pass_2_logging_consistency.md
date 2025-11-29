# Harden Pass 2: Logging Consistency

**Date:** 2025-11-28 22:50
**Scope:** Additional review of executor logging consistency

## Summary

Second pass of hardening found additional `warn` calls that should use `Minigun.logger.warn` for consistency.

## Findings

### Additional `warn` → `Minigun.logger.warn` Fixes

After the first harden pass fixed Ractor-related warnings, a deeper review found 4 more instances in the fork executors:

1. **CowForkPoolExecutor (line 197)** - Platform forking unavailable fallback
2. **CowForkPoolExecutor (line 293)** - Fork failure fallback
3. **IpcForkPoolExecutor (line 369)** - Platform forking unavailable fallback
4. **IpcForkPoolExecutor (line 469)** - Worker fork failure

## Changes Applied

All 4 instances changed from:
```ruby
warn '[Minigun] ...'
```

To:
```ruby
Minigun.logger.warn '[Minigun] ...'
```

## Rationale

- **Consistency**: All warning messages should go through the same logging mechanism
- **Configurability**: Users can configure `Minigun.logger` to route warnings appropriately
- **Testability**: Easier to capture and test warning output via logger

## Risk Assessment

- **Low risk** - No behavioral changes, only logging mechanism changed
- All executor classes now use consistent `Minigun.logger.warn` pattern

## Combined Fix Summary (Both Harden Passes)

Total of 6 `warn` → `Minigun.logger.warn` fixes:
- 2 in RactorPoolExecutor (lines 763, 773)
- 2 in CowForkPoolExecutor (lines 197, 293)
- 2 in IpcForkPoolExecutor (lines 369, 469)

Plus:
- Removed dead `create_shareable_wrapper` method
- Fixed misleading comment about Struct vs Class
