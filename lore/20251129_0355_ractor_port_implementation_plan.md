# Ractor Support Implementation Plan (Ruby 4.0 Ractor::Port API)

**Date:** 2025-11-29
**Feature:** Implement true parallel execution using Ruby 4.0's new Ractor::Port API
**Status:** PLANNED

## Executive Summary

Implement a `RactorPoolExecutor` that provides true parallelism using Ruby 4.0's new `Ractor::Port` API. This replaces the current stub implementation that falls back to threads.

## Background Research

### Ruby 4.0 Ractor::Port Changes

The Ractor API was significantly redesigned in Ruby 4.0:

**New API:**
- `Ractor::Port.new` - Create a new port for message passing
- `Ractor::Port#send(obj)` / `Ractor::Port#<<(obj)` - Send message to port (never blocks, infinite queue)
- `Ractor::Port#receive` - Receive message from port (blocks if empty)
- `Ractor::Port#close` / `Ractor::Port#closed?` - Close/check port status
- `Ractor#default_port` - Each Ractor has a default port
- `Ractor#join` / `Ractor#value` - Wait for termination
- `Ractor.shareable_proc` / `Ractor.shareable_lambda` - Create shareable procs
- `Ractor.select(ports_or_ractors)` - Wait on multiple ports/ractors

**Removed API (breaking changes from Ruby 3.x):**
- `Ractor.yield` - REMOVED
- `Ractor#take` - REMOVED
- `Ractor#close_incoming` - REMOVED
- `Ractor#close_outgoing` - REMOVED

**Critical Constraint:**
- **Only the creator Ractor can receive from a port** - This means the pattern must be:
  - Main Ractor creates `result_port`
  - Worker Ractors send TO `result_port`
  - Main Ractor receives FROM `result_port`

### Shareability Rules

Objects that can be shared between Ractors without copying:
- Integers, Symbols
- Frozen strings, arrays, hashes (deeply frozen)
- `Ractor.shareable_proc` / `Ractor.shareable_lambda` procs

Objects that must be copied (serialized):
- Unfrozen mutable objects
- Regular procs/lambdas

### Comparison with IPC Forks

| Aspect | IPC Forks | Ractors |
|--------|-----------|---------|
| Isolation | Process-level | Thread-level (memory isolated) |
| Communication | Marshal over pipes | Ractor::Port (object passing) |
| Overhead | High (process spawn) | Low (thread-like) |
| True parallelism | Yes | Yes |
| GIL bypass | Yes (separate process) | Yes (designed for it) |
| Memory | Full copy on fork | COW-like for shareable objects |
| User code constraints | Serializable results | Must not capture non-shareable refs |

### Implementation Mapping: IpcForkPoolExecutor → RactorPoolExecutor

The `RactorPoolExecutor` implementation follows the same pattern as `IpcForkPoolExecutor`:

| Aspect | IpcForkPoolExecutor | RactorPoolExecutor |
|--------|--------------------|--------------------|
| **Worker creation** | `fork do ... end` | `Ractor.new do ... end` |
| **Send work to worker** | `Marshal.dump(item, pipe)` | `worker.send(item)` |
| **Worker receives work** | `Marshal.load(pipe)` | `Ractor.receive` |
| **Worker sends result** | `Marshal.dump(result, pipe)` | `result_port << result` |
| **Main receives result** | `read_result_from_pipe` | `result_port.receive` |
| **Shutdown signal** | `Marshal.dump({type: :end_of_stage})` | `worker.send(:shutdown)` |
| **Wait for completion** | `Process.wait2` | `worker.join` |

Key differences from IPC forks:
1. **No pipes/Marshal** - Ractor uses object passing (shareable objects are zero-copy, others are deep-copied automatically)
2. **Port ownership** - Only creator can `receive` from a port (vs pipes where either end can read/write)
3. **Block constraints** - Stage blocks must be Ractor-shareable (no mutable captures)

The `IpcForkPoolExecutor` pattern at `lib/minigun/execution/executor.rb:360-648` is almost directly translatable - just swap the IPC pipe communication for Ractor::Port communication.

## Current State

The DSL already defines `in_ractors`:

```ruby
# lib/minigun/dsl.rb:273-275
def in_ractors(pool_size, &)
  context = { type: :ractor_pool, pool_size: pool_size }
  _with_execution_context(context, &)
end
```

The current `RactorPoolExecutor` is a stub that falls back to `ThreadPoolExecutor`:

```ruby
# lib/minigun/execution/executor.rb:725-742
class RactorPoolExecutor < Executor
  def initialize(stage_ctx, max_size: nil, pool_timeout: nil)
    super(stage_ctx)
    @max_size = max_size || 5
    @fallback = ThreadPoolExecutor.new(stage_ctx, max_size: max_size)
  end

  def execute_stage(stage, user_context, input_queue, output_queue)
    unless defined?(::Ractor)
      warn '[Minigun] Ractors not available, falling back to thread pool'
      return @fallback.execute_stage(stage, user_context, input_queue, output_queue)
    end
    # NOTE: Ractors have similar IPC challenges as process pools
    # Fall back to threads for now
    @fallback.execute_stage(stage, user_context, input_queue, output_queue)
  end
end
```

## Implementation Plan

### Phase 1: Platform Detection

**File:** `lib/minigun/platform.rb`

Add Ractor detection:

```ruby
# Check if Ractor with Port API is available (Ruby 4.0+)
def ractors?
  return @ractors if defined?(@ractors)

  @ractors = defined?(::Ractor) &&
             defined?(::Ractor::Port) &&
             Ractor::Port.respond_to?(:new)
end
```

### Phase 2: RactorPoolExecutor Implementation

**File:** `lib/minigun/execution/executor.rb`

Replace the stub `RactorPoolExecutor` with a working implementation:

```ruby
# Ractor pool executor - provides true parallelism using Ruby 4.0+ Ractor::Port API
# Each worker Ractor processes items from the main Ractor and sends results back.
#
# Architecture:
# - Main Ractor creates result_port (main can receive from it)
# - Workers receive work items via their default_port (Ractor.receive)
# - Workers send results to result_port
# - Main collects from result_port
#
# Constraints:
# - Stage blocks must be shareable (use Ractor.shareable_proc)
# - Input/output items must be shareable or will be copied
# - User context cannot be shared (must be recreated per-Ractor)
#
class RactorPoolExecutor < Executor
  attr_reader :max_size

  def initialize(stage_ctx, max_size: nil, pool_timeout: nil)
    super(stage_ctx)
    @max_size = max_size || 5
    @pool_timeout = pool_timeout
    @workers = []

    unless Minigun::Platform.ractors?
      # Create thread fallback for non-Ractor environments
      @fallback = ThreadPoolExecutor.new(stage_ctx, max_size: max_size, pool_timeout: pool_timeout)
    end
  end

  def execute_stage(stage, user_context, input_queue, output_queue)
    if @fallback
      warn '[Minigun] Ractors not available, falling back to thread pool'
      return @fallback.execute_stage(stage, user_context, input_queue, output_queue)
    end

    # Create result port - main Ractor can receive from this
    result_port = Ractor::Port.new

    # Create shareable proc from stage block if possible
    stage_proc = create_shareable_proc(stage)
    unless stage_proc
      warn '[Minigun] Stage block is not Ractor-shareable, falling back to threads'
      @fallback ||= ThreadPoolExecutor.new(@stage_ctx, max_size: @max_size)
      return @fallback.execute_stage(stage, user_context, input_queue, output_queue)
    end

    # Spawn worker Ractors
    spawn_workers(stage_proc, result_port)

    # Distribute work and collect results
    begin
      distribute_work(input_queue, result_port, output_queue)
    ensure
      shutdown
    end
  end

  def shutdown
    @workers.each do |worker|
      worker.send(:shutdown)
    rescue Ractor::ClosedError
      # Already closed
    end
    @workers.each do |worker|
      worker.join
    rescue Ractor::RemoteError
      # Worker errored
    end
    @workers.clear
  end

  private

  def create_shareable_proc(stage)
    return nil unless stage.respond_to?(:block) && stage.block

    # Try to make the proc shareable
    # Note: User's block must not capture non-shareable state
    begin
      Ractor.make_shareable(stage.block.dup)
    rescue Ractor::IsolationError
      # Block captures non-shareable state
      nil
    end
  end

  def spawn_workers(stage_proc, result_port)
    @max_size.times do |i|
      worker = Ractor.new(stage_proc, result_port, i, name: "minigun-ractor-#{i}") do |proc, rport, id|
        loop do
          msg = Ractor.receive  # Receive from default port
          break if msg == :shutdown

          begin
            item = msg[:item]
            # Process item with the shareable proc
            results = []
            capture = ->(result) { results << result }
            proc.call(item, capture)

            # Send results back
            results.each { |r| rport << { type: :result, result: r } }
          rescue => e
            rport << { type: :error, error: e.message, backtrace: e.backtrace }
          end
        end
      end
      @workers << worker
    end
  end

  def distribute_work(input_queue, result_port, output_queue)
    worker_index = 0
    pending_count = 0
    all_sent = false

    # Thread to collect results from result_port
    collector = Thread.new do
      loop do
        msg = result_port.receive
        break if msg == :collector_done

        case msg[:type]
        when :result
          output_queue << msg[:result]
          pending_count -= 1
        when :error
          Minigun.logger.error "[Ractor] Error: #{msg[:error]}"
          pending_count -= 1
        end
      end
    end

    # Distribute items round-robin
    loop do
      item = input_queue.pop

      if item.is_a?(Minigun::EndOfStage)
        all_sent = true
        break
      end

      @workers[worker_index % @max_size].send({ item: item })
      worker_index += 1
      pending_count += 1
    end

    # Wait for all pending items to complete
    sleep 0.01 while pending_count > 0

    # Signal collector to stop
    result_port << :collector_done
    collector.join
  end
end
```

### Phase 3: Queue Wrappers for Ractor

**File:** `lib/minigun/queue_wrappers.rb`

Add `RactorOutputQueue` wrapper:

```ruby
# Output queue wrapper for Ractor stages
# Captures outputs and makes them available for sending back to main Ractor
class RactorOutputQueue
  def initialize
    @results = []
  end

  def <<(item)
    push(item)
  end

  def push(item, target: nil)
    if target
      @results << { target: target, result: item }
    else
      @results << item
    end
  end

  def results
    @results
  end

  def to_proc
    ->(item) { push(item) }
  end
end
```

### Phase 4: DSL Enhancements

**File:** `lib/minigun/dsl.rb`

Add option for declaring shareable stage blocks:

```ruby
# Mark a stage block as shareable for Ractor execution
# This validates that the block doesn't capture non-shareable state
def shareable_stage(name, **opts, &block)
  shareable_block = Ractor.shareable_proc(&block)
  stage(name, **opts.merge(shareable: true), &shareable_block)
rescue ArgumentError => e
  raise Minigun::Error, "Stage :#{name} block is not Ractor-shareable: #{e.message}"
end
```

### Phase 5: Documentation & Examples

**File:** `examples/27_ractor_execution.rb` (update)

```ruby
#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

# Demonstrates Ractor-based parallel execution with Ruby 4.0+ Ractor::Port API
#
# Requirements:
# - Ruby 4.0+ (uses Ractor::Port for communication)
# - Stage blocks must not capture non-shareable state
#
# Ractors provide TRUE parallelism - each Ractor runs on its own OS thread
# without GIL restrictions. This is ideal for CPU-bound workloads.

class RactorExample
  include Minigun::DSL

  attr_reader :results

  def initialize
    @results = Ractor.make_shareable([].freeze) # Use shareable array
  end

  pipeline do
    producer :generate do |output|
      10.times { |i| output << i }
    end

    # Ractors provide true parallelism
    # Stage block must be pure (no captures of mutable state)
    in_ractors(4) do
      processor :compute do |item, output|
        # CPU-intensive work benefits from true parallelism
        result = (1..1000).reduce(item) { |acc, _| Math.sqrt(acc**2 + 1) }
        output << { input: item, computed: result }
      end
    end

    consumer :collect do |item|
      puts "Computed: #{item[:input]} -> #{item[:computed].round(4)}"
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  if Minigun::Platform.ractors?
    puts "Running with Ruby #{RUBY_VERSION} Ractor support"
    example = RactorExample.new
    example.run
  else
    puts "Ractors not available (requires Ruby 4.0+)"
    puts "Current Ruby: #{RUBY_VERSION}"
  end
end
```

## Key Design Decisions

### 1. Communication Pattern

Use the "result port" pattern:
- Main creates `result_port` (main can receive)
- Workers receive work via default port (`Ractor.receive`)
- Workers send results to `result_port`
- Main collects from `result_port`

This follows Ractor::Port's constraint that only the creator can receive.

### 2. Shareable Blocks

Stage blocks must be shareable to work with Ractors. Options:
1. **Automatic conversion** - Try `Ractor.make_shareable(block)` (may fail)
2. **Explicit declaration** - User uses `shareable_stage` helper
3. **Fallback** - Fall back to threads if block not shareable

Recommendation: Try automatic conversion first, fallback to threads with warning.

### 3. User Context

The `user_context` (typically `self` from the pipeline class) cannot be shared between Ractors. Options:
1. **No context** - Ractor stages don't have access to instance variables
2. **Shareable data** - Pass frozen/shareable data explicitly
3. **Recreate** - Each Ractor creates its own context instance

Recommendation: Ractor stages operate without user context (pure functions).

### 4. Error Handling

- Errors in Ractors are wrapped in `Ractor::RemoteError`
- Propagate error details back via result_port
- Log errors and continue processing other items

### 5. Graceful Degradation

If Ractors unavailable or block not shareable:
- Fall back to `ThreadPoolExecutor`
- Log warning explaining why

## File Changes Summary

### Modified Files

| File | Changes |
|------|---------|
| `lib/minigun/platform.rb` | Add `Platform.ractors?` detection |
| `lib/minigun/execution/executor.rb` | Replace `RactorPoolExecutor` stub with full implementation |
| `lib/minigun/queue_wrappers.rb` | Add `RactorOutputQueue` class |
| `examples/27_ractor_execution.rb` | Update with working Ractor example |

### New Files

| File | Purpose |
|------|---------|
| `spec/unit/execution/ractor_executor_spec.rb` | Unit tests for RactorPoolExecutor |
| `spec/integration/ractor_execution_spec.rb` | Integration tests |

## Testing Strategy

### Unit Tests

1. `Platform.ractors?` returns correct value based on Ruby version
2. `RactorPoolExecutor` initialization with/without Ractor support
3. Worker spawning and communication
4. Error handling within Ractors
5. Graceful fallback to threads

### Integration Tests

1. Basic Ractor pipeline execution
2. Multiple Ractor stages in sequence
3. Ractor + thread mixed pipelines
4. Large data set processing
5. Graceful shutdown mid-execution

### Skip Conditions

Tests should be skipped if:
- Ruby version < 4.0
- `Ractor::Port` not defined
- Platform doesn't support Ractors (JRuby, etc.)

## Open Questions

1. **User context handling** - Should we support a limited form of context (frozen data only)?

2. **Ractor pool reuse** - Should workers persist across multiple stage executions or spawn fresh?

3. **Move vs Copy semantics** - Should we use `move: true` for input items to avoid copies?

4. **Monitoring/stats** - How to aggregate stats from Ractor workers back to main?

## Success Criteria

1. **Functional**: `in_ractors(n)` executes stages with true parallelism
2. **Correct API**: Uses Ruby 4.0's Ractor::Port (not deprecated APIs)
3. **Fallback**: Falls back to threads gracefully on older Ruby or non-shareable blocks
4. **Tested**: Comprehensive unit and integration tests (skipped on unsupported platforms)
5. **Documented**: Clear documentation on Ractor constraints and requirements

## References

- [Ruby 4.0.0 Preview2 Release Notes](https://www.ruby-lang.org/en/news/2025/11/17/ruby-4-0-0-preview2-released/)
- [Ruby 4.0 Ractor Documentation](https://docs.ruby-lang.org/en/master/ractor_md.html)
- [Ruby 4.0 NEWS](https://docs.ruby-lang.org/en/master/NEWS_md.html)
- [Fiber/Async Implementation Plan](./20251128_2330_fibers_async_plan.md) - Similar executor pattern
