# Graceful Shutdown Implementation Plan

## Overview

Implement a two-phase graceful shutdown system for Minigun:
1. **First Ctrl+C**: Graceful shutdown - signal producers to stop, let pipeline drain
2. **Second Ctrl+C**: Force quit - kill all child processes/threads immediately

## Current State Analysis

### Existing Infrastructure
- `Runner#shutdown_gracefully()` exists but is minimal (sleeps 0.5s, re-raises)
- `Worker#graceful_shutdown()` exists and sends `EndOfSource` signals downstream
- Queue signal system (`EndOfSource`, `EndOfStage`) provides cascade mechanism
- Executors have `shutdown()` methods that kill child processes/threads
- IPC pipe tracking exists in `Task` for cross-pipeline cleanup

### Key Gaps
1. Runner doesn't track running pipelines/workers
2. Producers are not interruptible mid-iteration
3. No shutdown state tracking (can't distinguish first vs second Ctrl+C)
4. No mechanism to broadcast shutdown request to all stages
5. Thread pools may block indefinitely on queue reads

## Implementation Plan

### Phase 1: Shutdown State Machine

**File: `lib/minigun/runner.rb`**

Add shutdown state tracking:
```ruby
@shutdown_state = :running  # :running -> :graceful -> :forced
```

Modify signal handler:
- First signal: transition to `:graceful`, initiate graceful shutdown
- Second signal: transition to `:forced`, force quit

### Phase 2: Pipeline/Worker Tracking

**File: `lib/minigun/runner.rb` and `lib/minigun/pipeline.rb`**

- Runner tracks the current pipeline being run
- Pipeline exposes its workers for shutdown coordination
- Add `Pipeline#request_shutdown()` method

### Phase 3: Interruptible Producers

**File: `lib/minigun/stage.rb`**

Add shutdown checking to producer stages:
```ruby
class ProducerStage
  def check_shutdown!
    raise ShutdownRequested if @shutdown_requested
  end
end

class EnumeratorProducerStage
  def execute(stage_ctx)
    source.each do |item|
      check_shutdown!  # Check before each item
      output_queue << item
    end
  end
end
```

### Phase 4: Worker Shutdown Coordination

**File: `lib/minigun/worker.rb`**

- Add `@shutdown_requested` flag
- Add `request_shutdown()` method
- Modify run loop to check shutdown flag
- Gracefully unwind by sending `EndOfSource` signals

### Phase 5: Executor Graceful Shutdown

**File: `lib/minigun/execution/executor.rb`**

Add `graceful_shutdown()` vs `force_shutdown()` methods:

| Executor | Graceful | Force |
|----------|----------|-------|
| ThreadPoolExecutor | Set flag, let threads finish current item | Kill threads |
| CowForkPoolExecutor | Wait for current forks | SIGKILL |
| IpcForkPoolExecutor | Send `:shutdown`, wait with timeout, SIGTERM | SIGKILL |
| RactorPoolExecutor | Send shutdown message | Kill ractors |
| FiberPoolExecutor | Set flag, let fibers yield | Stop scheduler |

### Phase 6: Queue Timeout/Interrupt

**File: `lib/minigun/queue_wrappers.rb`**

Make queue reads interruptible:
- Use `Queue#pop(timeout: X)` pattern where available
- Add periodic shutdown checks during blocking reads
- Consider adding a `ShutdownSignal` queue message type

## Detailed Implementation Steps

### Step 1: Add ShutdownRequested Exception
```ruby
# lib/minigun/errors.rb
module Minigun
  class ShutdownRequested < StandardError; end
end
```

### Step 2: Add Shutdown State to Runner
```ruby
# lib/minigun/runner.rb
def initialize
  @shutdown_state = :running
  @current_pipeline = nil
  @shutdown_mutex = Mutex.new
end

def shutdown_gracefully
  @shutdown_mutex.synchronize do
    case @shutdown_state
    when :running
      @shutdown_state = :graceful
      initiate_graceful_shutdown
    when :graceful
      @shutdown_state = :forced
      force_shutdown
    end
  end
end
```

### Step 3: Add Pipeline Shutdown Interface
```ruby
# lib/minigun/pipeline.rb
def request_shutdown(force: false)
  @shutdown_requested = true
  @stage_workers.each { |w| w.request_shutdown(force: force) }
end
```

### Step 4: Make Workers Respond to Shutdown
```ruby
# lib/minigun/worker.rb
def request_shutdown(force: false)
  @shutdown_requested = true
  @force_shutdown = force
  @stage.request_shutdown if @stage.respond_to?(:request_shutdown)
  @executor&.request_shutdown(force: force)
end
```

### Step 5: Add Interruptibility to Producers
```ruby
# lib/minigun/stage.rb
class ProducerStage
  def request_shutdown
    @shutdown_requested = true
  end

  def check_shutdown!
    raise ShutdownRequested if @shutdown_requested
  end
end
```

### Step 6: Handle Shutdown in Stage Execution
```ruby
# Wrap stage execution in rescue
begin
  stage.run_stage(ctx)
rescue ShutdownRequested
  # Graceful exit, send end signals
  stage.send_end_signals(ctx)
end
```

### Step 7: Add Executor Graceful Shutdown Methods
```ruby
# lib/minigun/execution/executor.rb
class Executor
  def request_shutdown(force: false)
    @shutdown_requested = true
    @force_shutdown = force
  end

  def graceful_shutdown
    # Override in subclasses
  end
end
```

## Signal Flow Diagram

```
Ctrl+C (first)
    |
    v
Runner (state: :graceful)
    |
    v
Pipeline#request_shutdown
    |
    +---> Worker 1 ---> Stage 1 (producer) ---> stops iteration
    |                                      ---> sends EndOfSource
    |
    +---> Worker 2 ---> Stage 2 (processor) ---> finishes current
    |                                       ---> forwards EndOfSource
    |
    +---> Worker 3 ---> Stage 3 (consumer) ---> receives EndOfStage
                                           ---> completes

Ctrl+C (second, if hung)
    |
    v
Runner (state: :forced)
    |
    v
Pipeline#request_shutdown(force: true)
    |
    +---> All executors ---> SIGKILL children
    +---> All threads ---> Thread#kill
    +---> Re-raise signal for process exit
```

## Testing Strategy

### Unit Tests
1. Runner shutdown state transitions
2. Producer interruptibility
3. Worker shutdown flag propagation
4. Executor graceful vs force shutdown

### Integration Tests
1. Single Ctrl+C stops running pipeline gracefully
2. Double Ctrl+C force-kills hung pipeline
3. All child processes cleaned up after shutdown
4. No zombie processes after force quit
5. Pipeline with multiple stages shuts down in order

### Example Tests
```ruby
# spec/integration/graceful_shutdown_spec.rb
describe "Graceful Shutdown" do
  it "stops producers on first signal" do
    # Start pipeline with slow producer
    # Send SIGINT
    # Verify producer stopped
    # Verify downstream received EndOfStage
  end

  it "force kills on second signal" do
    # Start pipeline with blocking stage
    # Send first SIGINT
    # Send second SIGINT
    # Verify all processes killed
  end
end
```

## Edge Cases to Handle

1. **Shutdown during fork**: Don't leave orphan processes
2. **Shutdown during IPC communication**: Close pipes cleanly
3. **Shutdown with Ractors**: Handle Ractor isolation
4. **Shutdown with demand channels**: Close demand queues
5. **Multiple pipelines**: Shutdown all tracked pipelines
6. **Nested shutdowns**: Prevent double-shutdown

## Files to Modify

| File | Changes |
|------|---------|
| `lib/minigun/errors.rb` | Add `ShutdownRequested` exception |
| `lib/minigun/runner.rb` | Shutdown state machine, pipeline tracking |
| `lib/minigun/pipeline.rb` | `request_shutdown()` method |
| `lib/minigun/worker.rb` | Shutdown flag handling |
| `lib/minigun/stage.rb` | Interruptible producers |
| `lib/minigun/execution/executor.rb` | Graceful/force shutdown methods |
| `lib/minigun/queue_wrappers.rb` | Interruptible queue reads (if needed) |

## Success Criteria

- [ ] First Ctrl+C initiates graceful shutdown
- [ ] Producers stop generating new items
- [ ] In-flight items complete processing
- [ ] Second Ctrl+C forces immediate exit
- [ ] All child processes cleaned up
- [ ] No zombie processes
- [ ] No resource leaks (pipes, files)
- [ ] Works with all executor types (thread, fork, ractor)
