# Queue Classes Consolidation Assessment

## Overview

Reviewed all queue wrapper classes in Minigun to assess consolidation opportunities.

## Current Queue Classes

### Core Queues (`lib/minigun/queue_wrappers.rb`)
| Class | Purpose | Key Methods |
|-------|---------|-------------|
| `InputQueue` | Wraps input, handles EndOfSource signals | `pop` |
| `OutputQueue` | Routes items to downstream stages | `<<`, `to(target)`, `to_proc`, `shutdown?`, `shutdown!` |
| `IpcInputQueue` | Reads items from parent via IPC pipe | `pop` |
| `IpcOutputQueue` | Writes results to parent via IPC pipe | `<<`, `to(target)`, `to_proc`, `shutdown?`, `shutdown!` |
| `IpcRoutedOutputQueue` | IPC output with routing metadata | `<<`, `shutdown?`, `shutdown!` |

### Demand-Aware Queues (`lib/minigun/demand/aware_queues.rb`)
| Class | Purpose | Key Methods |
|-------|---------|-------------|
| `AwareInputQueue` | Wraps InputQueue + demand signaling | `pop`, `initialize_demand` |
| `AwareOutputQueue` | Wraps OutputQueue + demand gating | `<<`, `to(target)`, `to_proc`, `shutdown?`, `shutdown!`, demand API |
| `AwareTargetedOutputQueue` | Wraps targeted OutputQueue + demand | `<<`, `shutdown?`, `shutdown!` |

## Code Duplication Found

### 1. IPC Shutdown Methods (High)
`IpcOutputQueue` and `IpcRoutedOutputQueue` have **identical** implementations:
```ruby
# Both classes have this exact code:
def shutdown?
  @shutdown_requested
end

def shutdown!(force: false)
  @shutdown_requested = true
  begin
    Marshal.dump({ type: :shutdown_request, force: force }, @pipe_writer)
    @pipe_writer.flush
  rescue IOError, Errno::EPIPE
    # Pipe closed
  end
end
```

### 2. IPC Serialization Error Handling (High)
Both IPC output classes have identical error handling patterns for Marshal failures.

### 3. to_proc Implementation (Medium)
`OutputQueue` and `AwareOutputQueue` have nearly identical `to_proc` implementations. `IpcOutputQueue` has a simplified version that ignores routing.

### 4. Demand Waiter Pattern (Low)
`AwareOutputQueue` and `AwareTargetedOutputQueue` both include `DemandWaiter` - this is already well-factored via module.

## Consolidation Opportunities

### Recommended: Extract IPC Base Module

**Confidence: 95%** - Obvious win

Extract shared IPC behavior into a module:

```ruby
module IpcOutputBehavior
  def shutdown?
    @shutdown_requested
  end

  def shutdown!(force: false)
    @shutdown_requested = true
    ipc_send({ type: :shutdown_request, force: force })
  end

  private

  def ipc_send(message)
    Marshal.dump(message, @pipe_writer)
    @pipe_writer.flush
  rescue IOError, Errno::EPIPE
    # Pipe closed
  end

  def ipc_send_result(item, type: :result)
    ipc_send({ type: type, result: item })
    @stage_stats&.increment_produced
  rescue TypeError, ArgumentError => e
    Minigun.logger.warn "[Minigun] Cannot serialize result: #{e.message}"
    ipc_send({ type: :serialization_error, error: e.message, item_type: item.class.to_s })
  end
end
```

### Consider: Abstract Output Interface

**Confidence: 70%** - Good for type safety, may be overengineering

All output queues share this interface:
- `<<(item)` - send item
- `shutdown?` - check state
- `shutdown!(force:)` - request shutdown

Could define a formal interface or abstract class, but Ruby's duck typing makes this optional.

### NOT Recommended: Merge Aware + Base Queues

**Confidence: 90%** - Current design is correct

The wrapper pattern for demand-aware queues is deliberate:
- Demand is opt-in via pipeline config
- Keeps core queues simple and testable
- Avoids conditional complexity in hot paths
- Clean separation of concerns

### NOT Recommended: Unify IPC + In-Process Queues

**Confidence: 95%** - Fundamentally different

IPC queues are fundamentally different:
- Cross-process vs in-memory communication
- Serialization required (Marshal)
- Different error modes (IOError, pipe breaks)
- No access to shared memory/objects

## Verdict

**Consolidation: Minimal, targeted changes only**

The current architecture is sound. The only clear win is extracting shared IPC behavior into a module to reduce duplication between `IpcOutputQueue` and `IpcRoutedOutputQueue`.

### Proposed Changes

1. **Extract `IpcOutputBehavior` module** (~30 lines saved)
   - Shared shutdown methods
   - Shared serialization error handling
   - Shared pipe writing helper

2. **Keep everything else as-is**
   - Wrapper pattern is appropriate
   - Duck typing is sufficient for interfaces
   - IPC vs in-process split is correct

## Decision Matrix

| Change | Benefit | Risk | Recommendation |
|--------|---------|------|----------------|
| Extract IPC module | DRY, fewer bugs | Very low | **Do it** |
| Abstract output interface | Type safety | Overengineering | Skip |
| Merge Aware + Base | Less classes | Complexity | Skip |
| Unify IPC + Process | Fewer classes | Wrong abstraction | Skip |

## Implementation Estimate

If proceeding with the IPC module extraction:
- ~30 minutes of work
- Minimal test changes (behavior unchanged)
- Low risk

## IPC Queues and Demand Awareness

### Question: Should IPC queues have demand-aware variants?

**Answer: No** - The current design is correct.

### Data Flow Analysis

```
┌─────────────────────────────────────────────────────────────────┐
│                     PARENT PROCESS                              │
│                                                                 │
│  upstream → [AwareInputQueue] → distribute_work() → IPC pipe →  │
│                                                                 │
│  ← IPC pipe ← read_result_from_pipe() → [AwareOutputQueue] →    │
│                                           downstream            │
└─────────────────────────────────────────────────────────────────┘
                              ↕ IPC pipes
┌─────────────────────────────────────────────────────────────────┐
│                     CHILD PROCESS (fork)                        │
│                                                                 │
│  [IpcInputQueue] → stage.execute() → [IpcOutputQueue]           │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### Why Demand Works Without IPC Awareness

1. **Parent handles demand at stage boundaries**
   - `AwareInputQueue`: Signals consumption to upstream producers
   - `AwareOutputQueue`: Waits for demand from downstream consumers

2. **IPC is internal transport, not a stage boundary**
   - Child process is a worker within a single stage's execution
   - The parent orchestrates all inter-stage communication
   - Demand backpressure operates at stage-to-stage edges

3. **Child doesn't need demand because**
   - It can't access shared memory for demand channels (cross-process)
   - Parent already rate-limits input from upstream
   - Parent already respects downstream demand before forwarding results

### Code Flow

```ruby
# Parent process (executor.rb)
def execute_stage(stage, user_context, input_queue, output_queue)
  # input_queue = AwareInputQueue (if demand enabled)
  # output_queue = AwareOutputQueue (if demand enabled)
  distribute_work(input_queue, output_queue)  # Demand handled here
end

# Child process (executor.rb worker_loop)
def worker_loop(stage, ...)
  ipc_input_queue = IpcInputQueue.new(from_parent, stage)    # No demand needed
  ipc_output_queue = IpcOutputQueue.new(to_parent, stage_stats)  # No demand needed
  stage.execute(user_context, ipc_input_queue, ipc_output_queue, stage_stats)
end
```

### Potential Gap: IPC Pipe Buffering

One edge case exists: if the child produces faster than the parent consumes, items buffer in the IPC pipe. The OS pipe buffer provides some natural backpressure (blocking writes when full), but this isn't explicit demand-based flow control.

**Mitigations (if needed in future)**:
- Use bounded pipes with explicit size limits
- Add flow control messages to IPC protocol (ack/nack)
- Parent-side throttling before dispatching to child

**Current status**: Not a problem in practice - OS pipe buffering is sufficient.

## Implementation Status

**Completed**: Extracted `IpcOutputBehavior` module
- `IpcOutputQueue` and `IpcRoutedOutputQueue` now share:
  - `shutdown?` and `shutdown!` methods
  - `ipc_send` helper for pipe communication
  - `ipc_send_with_recovery` for serialization error handling
- ~40 lines of duplication removed
