# Harden Pass 3: Complete Executor Logging Cleanup

**Date:** 2025-11-28 22:55
**Scope:** Comprehensive logging consistency across all executor classes

## Summary

Third pass of hardening completed the full logging cleanup in executor.rb, converting all remaining raw `warn` calls to use `Minigun.logger.warn` or appropriate log levels.

## Changes Applied

### executor.rb - AbstractForkExecutor (lines 133-166)

1. **Line 133**: `warn "[Minigun] Target queue not found..."` → `Minigun.logger.warn`
2. **Line 137**: `warn "[Minigun] Target stage not found..."` → `Minigun.logger.warn`
3. **Line 152**: `warn "[Minigun] Skipped non-serializable..."` → `Minigun.logger.warn`
4. **Line 166**: `warn "[Minigun] Error reading from pipe..."` → `Minigun.logger.warn`

### executor.rb - CowForkPoolExecutor (lines 282-340)

5. **Lines 282-283**: Error in COW forked process
   - Changed from `warn` to `Minigun.logger.error` (error message)
   - Changed from `warn` to `Minigun.logger.debug` (backtrace)
6. **Line 340**: `warn "[Minigun] COW forked process failed..."` → `Minigun.logger.warn`

### executor.rb - IpcForkPoolExecutor (lines 575-577)

7. **Line 575**: `warn "[Minigun] Cannot serialize item..."` → `Minigun.logger.warn`
8. **Line 577**: `warn "[Minigun] Lost connection to worker..."` → `Minigun.logger.warn`

## Items Intentionally Left Unchanged

The following `warn` calls are intentionally left using Kernel `warn` for direct console output:

1. **dsl.rb (lines 537-538, 563-564)**: Background task error in IRB/console mode
   - Direct console output for user feedback during interactive sessions

2. **hud.rb (lines 73-74)**: HUD error handling
   - HUD IS the terminal UI, needs direct console output

3. **hud/controller.rb (lines 258, 269)**: Input handling and resize detection
   - HUD-specific terminal interactions

## Cumulative Fix Summary (All Harden Passes)

### Total warn → Minigun.logger.* fixes: 14

**RactorPoolExecutor (Pass 1-2):**
- 2 fixes (lines 763, 773)

**CowForkPoolExecutor (Pass 2-3):**
- 4 fixes (lines 197, 282-283, 293, 340)

**IpcForkPoolExecutor (Pass 2-3):**
- 4 fixes (lines 369, 469, 575, 577)

**AbstractForkExecutor (Pass 3):**
- 4 fixes (lines 133, 137, 152, 166)

### Additional Cleanups (Pass 1):
- Removed dead `create_shareable_wrapper` method
- Fixed misleading comment about Struct vs Class

## Risk Assessment

- **Low risk** - No behavioral changes
- **Improved**: Consistent logging across all execution strategies
- **Improved**: Proper log levels (error/warn/debug) based on severity

## Log Level Guidelines Applied

- `Minigun.logger.error` - Actual errors that occurred during processing
- `Minigun.logger.warn` - Fallbacks, skipped items, recoverable issues
- `Minigun.logger.debug` - Detailed debugging info (backtraces, internal state)
