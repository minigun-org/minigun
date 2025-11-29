# Fiber Support with Async Gem - Implementation Plan

**Date:** 2025-11-28
**Feature:** Optional `in_fibers` support using the `async` gem
**Status:** IMPLEMENTED

## Executive Summary

Add optional fiber-based concurrency to Minigun via the [`async`](https://github.com/socketry/async) gem. When enabled, `in_fibers(n)` will use `Async::Semaphore` to limit concurrent fibers, providing lightweight cooperative concurrency for I/O-bound workloads.

## Background Research

### Async Gem Overview

The [async gem](https://github.com/socketry/async) provides:
- Light-weight fiber-based concurrency (thousands of fibers per process)
- Cooperative scheduling via Ruby 3.0+ Fiber Scheduler
- `Async::Semaphore` for limiting concurrent operations
- `Async::Barrier` for waiting on multiple tasks
- Non-blocking I/O for network, file, and sleep operations

### Key API Patterns

```ruby
require 'async'

# Basic async block
Async do |task|
  result = task.async { expensive_io_operation }
  result.wait
end

# Semaphore for concurrency limiting
semaphore = Async::Semaphore.new(5)  # max 5 concurrent
semaphore.async do
  # Runs when slot available
end
```

### Fibers vs Threads

| Aspect | Fibers (async) | Threads |
|--------|---------------|---------|
| Weight | Very light (~4KB) | Heavier (~1MB stack) |
| Scheduling | Cooperative (yields on I/O) | Preemptive (OS-managed) |
| GIL | Not applicable | Limited by GIL for CPU |
| Best for | I/O-bound (HTTP, DB, files) | CPU-bound or mixed |
| Parallelism | None (single thread) | Limited by GIL |

## Current State

The DSL already defines `in_fibers`:

```ruby
# lib/minigun/dsl.rb:263-266
def in_fibers(pool_size, &)
  context = { type: :fiber_pool, pool_size: pool_size }
  _with_execution_context(context, &)
end
```

However:
1. No `FiberPoolExecutor` exists in `lib/minigun/execution/executor.rb`
2. Worker expects `:fiber_pool` type but factory has no case for it
3. No async gem integration

## Implementation Plan

### Phase 1: Optional Dependency Setup

#### 1.1 Add async as optional dev dependency

**File:** `Gemfile`

```ruby
# Optional async support for fiber-based concurrency
gem 'async', group: :development
```

**File:** `minigun.gemspec` - No changes (keep async optional)

#### 1.2 Create async availability check

**File:** `lib/minigun/platform.rb`

Add method to detect async gem availability:

```ruby
def self.fibers?
  return @async_available if defined?(@async_available)

  @async_available = begin
    require 'async'
    require 'async/semaphore'
    require 'async/barrier'
    true
  rescue LoadError
    false
  end
end
```

### Phase 2: FiberPoolExecutor Implementation

#### 2.1 Create FiberPoolExecutor

**File:** `lib/minigun/execution/executor.rb`

Add new executor class:

```ruby
# Fiber pool executor - uses async gem for cooperative concurrency
# Best for I/O-bound workloads (HTTP requests, database queries, file I/O)
class FiberPoolExecutor < Executor
  attr_reader :max_size

  def initialize(stage_ctx, max_size: nil)
    super(stage_ctx)
    @max_size = max_size || 5

    unless Minigun::Platform.fibers?
      raise Minigun::Error,
        "Fiber execution requires the 'async' gem. Add `gem 'async'` to your Gemfile."
    end

    require 'async'
    require 'async/semaphore'
    require 'async/barrier'
  end

  def execute_stage(stage, user_context, input_queue, output_queue)
    # Run within Async reactor
    Sync do
      semaphore = Async::Semaphore.new(@max_size)
      barrier = Async::Barrier.new(semaphore)

      # Process items concurrently with semaphore limiting
      loop do
        item = input_queue.pop
        break if item.is_a?(Minigun::EndOfStage)

        # Spawn fiber for each item (semaphore limits concurrency)
        barrier.async do
          process_item(stage, user_context, item, output_queue)
        end
      end

      # Wait for all fibers to complete
      barrier.wait
    end
  end

  def shutdown
    # Fibers are automatically cleaned up when Sync block exits
  end

  private

  def process_item(stage, user_context, item, output_queue)
    start_time = Time.now if @stage_ctx.stage_stats

    if stage.respond_to?(:block) && stage.block
      user_context.instance_exec(item, output_queue, &stage.block)
    elsif stage.respond_to?(:call)
      stage.call_with_arity(item, output_queue, &output_queue.to_proc)
    end

    @stage_ctx.stage_stats&.record_latency(Time.now - start_time)
  rescue StandardError => e
    Minigun.logger.error "[Stage:#{@stage_ctx.stage.name}] Fiber error: #{e.message}"
    Minigun.logger.debug e.backtrace.join("\n") if Minigun.logger.debug?
  end
end
```

#### 2.2 Register in executor factory

**File:** `lib/minigun/execution/executor.rb`

Update factory method:

```ruby
def self.create_executor(type, ...)
  case type
  when :inline
    InlineExecutor.new(...)
  when :thread
    ThreadPoolExecutor.new(...)
  when :fiber
    FiberPoolExecutor.new(...)  # ADD THIS
  when :cow_fork
    CowForkPoolExecutor.new(...)
  when :ipc_fork
    IpcForkPoolExecutor.new(...)
  when :ractor
    RactorPoolExecutor.new(...)
  else
    raise ArgumentError, "Unknown executor type: #{type}. Valid types: :inline, :thread, :fiber, :cow_fork, :ipc_fork, :ractor"
  end
end
```

#### 2.3 Update DSL normalization

**File:** `lib/minigun/dsl.rb`

The `normalize_execution_type` method already handles this:

```ruby
def normalize_execution_type(type)
  type.to_s.delete_suffix('s').delete_suffix('_pool').to_sym
end
```

This converts `:fiber_pool` → `:fiber`, which matches our factory.

### Phase 3: Queue Integration

#### 3.1 Fiber-safe queue wrapper (if needed)

The async gem's fiber scheduler automatically handles blocking on Queue operations, so standard Ruby queues should work. However, we may need to verify:

1. `SizedQueue#push` blocks correctly (yields fiber on full)
2. `Queue#pop` blocks correctly (yields fiber on empty)

If issues arise, create `FiberSafeQueue` wrapper using `Async::Queue`.

### Phase 4: Demand Integration

The demand-based backpressure system should work with fibers since:
- `ConditionVariable#wait` yields to fiber scheduler
- `Mutex#synchronize` yields on contention

May need testing to confirm fiber-friendly behavior.

### Phase 5: Documentation & Examples

#### 5.1 Update guides

**File:** `docs/guides/06_execution_strategies.md`

Add section on fiber execution:

```markdown
## Fiber Execution (async gem)

For I/O-bound workloads, fibers provide lightweight concurrency:

```ruby
pipeline do
  in_fibers(100) do
    consumer :fetch_urls do |url, output|
      # Fiber yields during HTTP request
      response = Net::HTTP.get(URI(url))
      output << { url: url, body: response }
    end
  end
end
```

**Requirements:** Add `gem 'async'` to your Gemfile.

**Best for:** HTTP requests, database queries, file I/O, API calls.

**Not ideal for:** CPU-bound processing (use threads or forks).
```

#### 5.2 Add example

**File:** `examples/10_fiber_concurrency.rb`

```ruby
#!/usr/bin/env ruby
require 'minigun'
require 'async'
require 'net/http'

class FiberCrawler
  include Minigun::DSL

  pipeline do
    produce_each :urls, %w[
      https://example.com
      https://httpbin.org/get
      https://jsonplaceholder.typicode.com/posts/1
    ]

    in_fibers(10) do
      consumer :fetch do |url, output|
        uri = URI(url)
        response = Net::HTTP.get_response(uri)
        output << { url: url, status: response.code }
      end
    end

    consumer :print do |result|
      puts "#{result[:url]} => #{result[:status]}"
    end
  end
end

FiberCrawler.new.run
```

## File Changes Summary

### New Files

| File | Purpose |
|------|---------|
| `spec/unit/execution/fiber_executor_spec.rb` | Unit tests for FiberPoolExecutor |
| `spec/integration/fiber_concurrency_spec.rb` | Integration tests |
| `examples/10_fiber_concurrency.rb` | Usage example |

### Modified Files

| File | Changes |
|------|---------|
| `Gemfile` | Add `gem 'async'` as dev dependency |
| `lib/minigun/platform.rb` | Add `Platform.fibers?` detection |
| `lib/minigun/execution/executor.rb` | Add `FiberPoolExecutor` class and factory case |

## Testing Strategy

### Unit Tests

1. `FiberPoolExecutor` initialization with/without async gem
2. Semaphore limiting (verify max concurrent)
3. Error handling within fibers
4. Stats recording (latency per item)

### Integration Tests

1. Basic fiber pipeline execution
2. Multiple fiber stages in sequence
3. Fiber + thread mixed pipelines
4. Demand backpressure with fibers
5. Graceful shutdown mid-execution

### Performance Tests

1. Compare throughput: fibers vs threads for I/O-bound
2. Memory usage at high concurrency (100+ fibers)
3. Latency distribution

## Open Questions

1. **Queue compatibility**: Do Ruby's `Queue`/`SizedQueue` yield correctly to fiber scheduler?
   - If not, may need `Async::Queue` integration

2. **Demand channel compatibility**: Does `ConditionVariable#wait` work with fibers?
   - Should work with Ruby 3.0+ fiber scheduler

3. **Error propagation**: How do unhandled fiber errors propagate?
   - Need to ensure they don't crash the reactor

4. **Nested async blocks**: What if user code already uses `Async do`?
   - Should work - async supports nesting

## Success Criteria

1. **Functional**: `in_fibers(n)` executes stages with fiber concurrency
2. **Optional**: Works without async gem (raises helpful error)
3. **Performant**: Lower memory than threads at high concurrency
4. **Compatible**: Works with existing queue wrappers and demand system
5. **Tested**: Comprehensive unit and integration tests

## References

- [Async GitHub](https://github.com/socketry/async)
- [Async Getting Started](https://socketry.github.io/async/guides/getting-started/index.html)
- [Async::Semaphore](https://socketry.github.io/async/source/Async/Semaphore/index.html)
- [Ruby Fiber Scheduler](https://docs.ruby-lang.org/en/3.1/Fiber/Scheduler.html)
- [Ruby Concurrency Primer](https://www.toptal.com/ruby/ruby-concurrency-and-parallelism-a-practical-primer)

---

## Implementation Summary

### Files Changed

| File | Changes |
|------|---------|
| `Gemfile` | Added `gem 'async'` as optional dev dependency |
| `lib/minigun/platform.rb` | Added `Platform.fibers?` detection method |
| `lib/minigun/execution/executor.rb` | Added `FiberPoolExecutor` class and `:fiber` factory case |
| `spec/unit/execution/executor_spec.rb` | Added 9 unit tests for `FiberPoolExecutor` |
| `spec/integration/fiber_concurrency_spec.rb` | Added 6 integration tests |
| `spec/integration/examples_spec.rb` | Added test for fiber example |
| `examples/100_fiber_concurrency.rb` | Created usage example |

### Key Implementation Details

1. **FiberPoolExecutor** uses `Sync do` block to run fibers synchronously
2. **Async::Semaphore** limits concurrent fibers to `max_size`
3. **Async::Barrier** (with `parent: semaphore`) coordinates fiber completion
4. Errors are caught per-fiber and logged, allowing other fibers to continue
5. Stats latency is recorded per item

### Test Results

- **825 total tests** (all passing)
- **9 unit tests** for FiberPoolExecutor
- **6 integration tests** for fiber pipelines
- **1 example test** for 100_fiber_concurrency.rb

### Performance Example

From the example run:
```
Fibers:  0.08s (30 pages)
Threads: 0.62s (30 pages)
```

Fibers outperformed threads ~7.75x for I/O-bound workloads in this test.
