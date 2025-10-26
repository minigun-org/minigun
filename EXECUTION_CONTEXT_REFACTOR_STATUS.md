# Execution Context Refactor - IN PROGRESS

## Goals
1. ✅ Create `IPCTransport` class for unified IPC handling
2. ✅ Separate `ForkContext` (COW) from `ProcessPoolContext` (IPC pool)
3. ✅ Make ALL stages have an execution context (default to inline)
4. ✅ Always delegate stage execution to `StageExecutor`
5. 🔄 Fix test failures (in progress)

## Changes Made

### 1. IPCTransport Class ✅
**File**: `lib/minigun/execution/ipc_transport.rb` (NEW - 125 lines)
- Bidirectional pipe management
- Marshal-based serialization
- Error propagation across process boundaries
- PID tracking and lifecycle management

###  2. Context Refactoring ✅
**File**: `lib/minigun/execution/context.rb`

**ForkContext** (COW Fork - one-time use):
- Uses `IPCTransport`
- Spawns process → execute → marshal result → exit
- For `process_per_batch`

**ProcessPoolContext** (IPC Pool - persistent workers):
- Uses `IPCTransport`  
- Spawns worker once → event loop → process multiple items
- For `processes(N) do`

### 3. Universal Execution Contexts ✅
**File**: `lib/minigun/stage.rb`
```ruby
def execution_context
  @options[:_execution_context] || { type: :inline, mode: :inline }
end
```
Every stage now has an execution context, defaulting to inline.

### 4. Unified Stage Execution ✅
**File**: `lib/minigun/pipeline.rb`
```ruby
def execute_stage(stage, item)
  # ALL stages now have an execution context (defaults to inline)
  # Always delegate to StageExecutor for consistent execution
  require_relative 'execution/stage_executor'
  executor = Execution::StageExecutor.new(self, @config)
  item_data = { item: item, stage: stage }
  executor.execute_with_context(stage.execution_context, [item_data])
end
```

**File**: `lib/minigun/execution/stage_executor.rb`
- Made `execute_with_context` public
- Refactored `execute_inline` to properly handle stats, hooks, and emit
- Returns collected output items

## Current Issues

###  Test Failures
**Status**: 86 failures (was 0, increased after refactor)

**Main Categories**:
1. **Inline execution** - emit methods, stats tracking, hooks not fully working
2. **Result propagation** - Some stages not returning results correctly
3. **Mixed pipeline routing** - Complex routing scenarios failing

**Examples of failures**:
- Mixed pipeline/stage routing tests
- emit_to_stage tests
- Complex topology tests

## What's Working ✅
- IPCTransport abstraction
- Context type separation (fork vs process pool)
- Default execution contexts
- Basic structure of unified execution

## What Needs Fixing 🔄
1. **Inline execution completeness** - ensure all features work (emit, stats, hooks)
2. **Result propagation** - verify results flow correctly through all paths
3. **Process pool execution** - test with actual IPC examples
4. **Test suite** - get back to 0 failures

## Next Steps
1. Debug why inline execution isn't collecting all results
2. Verify `@output_items` is being populated and returned correctly
3. Test process pool IPC with new examples (46-50)
4. Fix remaining test failures systematically

## Files Modified
1. `lib/minigun/execution/ipc_transport.rb` - NEW
2. `lib/minigun/execution/context.rb` - Added ProcessPoolContext, refactored ForkContext
3. `lib/minigun/stage.rb` - Added default execution context
4. `lib/minigun/pipeline.rb` - Simplified execute_stage
5. `lib/minigun/execution/stage_executor.rb` - Refactored inline execution, made execute_with_context public

## Documentation Created
1. `PROCESS_POOL_IPC_DESIGN.md` - Architecture and two fork types
2. `IPC_TRANSPORT_SUMMARY.md` - IPC transport refactoring details
3. `EXECUTION_CONTEXT_REFACTOR_STATUS.md` - This file

## Test Status Before/After
- Before: `363 examples, 0 failures, 3 pending` ✅
- After: `363 examples, 86 failures, 3 pending` ❌ (refactoring in progress)

The refactor is architecturally sound but needs debugging to restore all functionality.

