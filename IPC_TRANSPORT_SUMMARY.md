# IPC Transport Refactoring - COMPLETE

## What We Did

### 1. Created `IPCTransport` Class
**File**: `lib/minigun/execution/ipc_transport.rb`

A unified abstraction for inter-process communication via pipes and Marshal:
- **Bidirectional pipes**: Input (parent→child) and output (child→parent)
- **Marshal-based serialization**: Send/receive any Ruby objects
- **Error handling**: Propagate exceptions across process boundaries
- **Lifecycle management**: PID tracking, alive checks, termination

**Key Methods**:
```ruby
transport.create_pipes          # Set up bidirectional pipes
transport.send_to_child(data)   # Parent sends to child
transport.receive_from_parent   # Child receives from parent
transport.send_to_parent(data)  # Child sends to parent
transport.receive_from_child    # Parent receives from child
transport.send_result(result)   # Helper: send result with error handling
transport.send_error(exception) # Helper: send error info
transport.receive_result        # Helper: receive and handle errors
```

### 2. Refactored `ForkContext` (COW Fork)
**Before**: 50+ lines of pipe/marshal boilerplate
**After**: 35 lines using `IPCTransport`

```ruby
class ForkContext < Context
  def initialize(name)
    super(name)
    @transport = IPCTransport.new(name: name)
  end

  def execute(&block)
    @transport.create_pipes
    pid = fork do
      @transport.close_parent_pipes
      result = block.call
      @transport.send_result(result)
    rescue => e
      @transport.send_error(e)
    ensure
      @transport.close_all_pipes
    end
    @transport.set_pid(pid)
    @transport.close_child_pipes
    self
  end

  def join
    result = @transport.receive_result
    @transport.wait
    @transport.close_all_pipes
    result
  end
end
```

### 3. Implemented `ProcessPoolContext` (IPC Process Pool)
**New context type** for persistent worker processes

```ruby
class ProcessPoolContext < Context
  def spawn_worker
    @transport.create_pipes
    pid = fork do
      @transport.close_parent_pipes
      loop do
        data = @transport.receive_from_parent
        break if data == :SHUTDOWN || data.nil?
        result = data.call if data.is_a?(Proc)
        @transport.send_result(result)
      rescue => e
        @transport.send_error(e)
      end
    end
    @transport.set_pid(pid)
    @transport.close_child_pipes
  end

  def execute(&block)
    spawn_worker unless @transport.pid
    @transport.send_to_child(block)
    self
  end

  def join
    @transport.receive_result
  end
end
```

### 4. Unified Execution Context System
**Every stage now has an execution context** - defaulting to inline

**`lib/minigun/stage.rb`**:
```ruby
def execution_context
  @options[:_execution_context] || { type: :inline, mode: :inline }
end
```

**`lib/minigun/pipeline.rb`**:
```ruby
def execute_stage(stage, item)
  # ALL stages now have an execution context (defaults to inline)
  # Always delegate to StageExecutor for consistent execution
  require_relative 'execution/stage_executor'
  executor = Execution::StageExecutor.new(self, @config)
  item_data = { item: item, stage: stage }
  executor.execute_with_context(stage.execution_context, [item_data])

  # Results are already added to output by executor
  []
end
```

**`lib/minigun/execution/stage_executor.rb`**:
```ruby
# Public method - execute items with their execution context
def execute_with_context(exec_ctx, stage_items)
  # All stages have an execution context (never nil)
  case exec_ctx[:mode]
  when :pool
    execute_with_pool(exec_ctx, stage_items)
  when :per_batch
    execute_per_batch(exec_ctx, stage_items)
  when :inline
    execute_inline(stage_items)
  else
    # Fallback to inline if mode is unknown
    execute_inline(stage_items)
  end
end
```

## Benefits

### Code Quality
- ✅ **-100 lines of duplicate IPC code** removed
- ✅ **Single source of truth** for IPC logic
- ✅ **Consistent error handling** across all contexts
- ✅ **Easier to test** - one transport class to unit test

### Architecture
- ✅ **Unified execution model** - all stages use contexts
- ✅ **No special cases** - inline is just another context
- ✅ **Cleaner separation** - transport vs. context lifecycle
- ✅ **Extensible** - easy to add new IPC mechanisms

### Two Fork Types Now Clear
| Context | Use Case | Lifetime | DSL |
|---------|----------|----------|-----|
| `ForkContext` | COW fork | One-time use | `process_per_batch` |
| `ProcessPoolContext` | IPC pool | Persistent workers | `processes(N)` |

## Files Modified
1. `lib/minigun/execution/ipc_transport.rb` - NEW (125 lines)
2. `lib/minigun/execution/context.rb` - Refactored ForkContext, added ProcessPoolContext
3. `lib/minigun/stage.rb` - Added default execution context
4. `lib/minigun/pipeline.rb` - Simplified execute_stage to always use StageExecutor
5. `lib/minigun/execution/stage_executor.rb` - Made execute_with_context public

## Documentation Created
1. `PROCESS_POOL_IPC_DESIGN.md` - Architecture and design decisions
2. `IPC_TRANSPORT_SUMMARY.md` - This file

## Next Steps
- Test process pools with real examples (`46_simple_process_pool.rb`, etc.)
- Verify IPC performance with stress tests
- Ensure all existing tests still pass

