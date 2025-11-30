# Comprehensive Error Handling Plan

**Date:** 2025-11-30
**Context:** Planning comprehensive error handling across all executor types and features

## Current State Analysis

### What Already Exists

| Feature | Location | Status |
|---------|----------|--------|
| Item-level error catching | `stage.rb:331-356` | ✅ Log and continue |
| Worker-level error catching | `worker.rb:50-55` | ✅ Log, thread dies |
| IPC fork restart policy | `executor.rb`, `worker_monitor.rb` | ✅ `:never`/`:transient`/`:permanent` |
| At-least-once delivery | `cluster/distributor.rb` | ✅ Retries with max_retries |
| Serialization error handling | `queue_wrappers.rb:194-226` | ✅ Graceful skip with warning |
| DAG validation errors | `dag.rb` | ✅ Raises `Minigun::Error` |
| Cluster connection errors | `cluster.rb` | ✅ `ConnectionError`, `WorkerNotFoundError` |

### Critical Gaps Identified

1. **Hook error handling** - Hooks can crash the entire pipeline with no recovery
2. **No stage-level retry mechanism** - Users must implement retry logic manually
3. **No circuit breaker** - Cascading failures not prevented
4. **No error aggregation** - Multiple errors not collected/reported together
5. **No pipeline-level error callback** - User can't receive notification of errors
6. **No timeout mechanisms** - Stages can hang indefinitely (except `pool_timeout` placeholder)

---

## Implementation Plan

### Phase 1: Hook Error Handling (High Priority)

**Problem:** Hooks execute without error handling in `pipeline.rb:258-272`. A failing hook crashes the entire pipeline.

**Solution:** Wrap hook execution with error handling, provide configurable behavior.

#### 1.1 Add HookError class

```ruby
# lib/minigun.rb
module Minigun
  class HookError < Error
    attr_reader :hook_type, :stage_name, :original_error

    def initialize(hook_type, stage_name, original_error)
      @hook_type = hook_type
      @stage_name = stage_name
      @original_error = original_error
      super("Hook #{hook_type}#{stage_name ? " for #{stage_name}" : ''} failed: #{original_error.message}")
    end
  end
end
```

#### 1.2 Update Pipeline hook execution

```ruby
# lib/minigun/pipeline.rb
def execute_stage_hooks(type, stage_or_name)
  name = stage_or_name.is_a?(Stage) ? stage_or_name.name : stage_or_name
  hooks = @stage_hooks.dig(type, name) || []
  hooks.each do |h|
    begin
      @context.instance_exec(&h)
    rescue StandardError => e
      handle_hook_error(type, name, e)
    end
  end
end

def handle_hook_error(type, stage_name, error)
  hook_error = HookError.new(type, stage_name, error)
  Minigun.logger.error "[Pipeline] #{hook_error.message}"
  Minigun.logger.debug error.backtrace.join("\n")

  case @hook_error_policy
  when :raise
    raise hook_error
  when :log
    # Already logged, continue
  when :callback
    @on_hook_error&.call(hook_error)
  end
end
```

#### 1.3 Add DSL configuration

```ruby
# lib/minigun/dsl.rb
def on_hook_error(policy = :log, &block)
  @hook_error_policy = policy
  @on_hook_error = block if block_given?
end
```

**Files to modify:**
- `lib/minigun.rb` - Add `HookError` class
- `lib/minigun/pipeline.rb` - Wrap hook execution
- `lib/minigun/dsl.rb` - Add `on_hook_error` DSL method

---

### Phase 2: Stage-Level Error Handling & Callbacks (High Priority)

**Problem:** Errors at item level are logged but users can't react to them programmatically.

**Solution:** Add error callbacks and error tracking at stage/pipeline level.

#### 2.1 Add error tracking to StageStats

```ruby
# lib/minigun/stage.rb
class StageStats
  attr_reader :error_count, :last_error

  def record_error(error, item)
    @error_mutex.synchronize do
      @error_count += 1
      @last_error = { error: error, item: item, time: Time.now }
    end
  end
end
```

#### 2.2 Add on_error callback to stages

```ruby
# lib/minigun/dsl.rb
def on_error(policy = :log, &block)
  @error_policy = policy
  @on_error = block
end

# Usage:
pipeline do
  on_error(:callback) do |error, item, stage|
    ErrorTracker.record(error, item, stage.name)
  end

  processor :risky do |item, output|
    output << dangerous_operation(item)
  end
end
```

#### 2.3 Integrate with stage execution

```ruby
# lib/minigun/stage.rb (ConsumerStage#execute)
begin
  context.instance_exec(item, output_queue, &@block)
rescue StandardError => e
  stage_stats.record_error(e, item)
  handle_item_error(e, item, context)
end

def handle_item_error(error, item, context)
  Minigun.logger.error "[Stage:#{name}] Error processing item: #{error.message}"

  case context.error_policy
  when :raise
    raise
  when :log
    # Already logged
  when :callback
    context.on_error&.call(error, item, self)
  when :dead_letter
    context.dead_letter_queue&.push({ item: item, error: error, stage: name })
  end
end
```

**Files to modify:**
- `lib/minigun/stage.rb` - Add error tracking to `StageStats`, update `execute` methods
- `lib/minigun/dsl.rb` - Add `on_error` DSL method
- `lib/minigun/pipeline.rb` - Pass error policy to stages

---

### Phase 3: Retry Mechanism with Backoff (Medium Priority)

**Problem:** No built-in retry mechanism. Users must implement retry logic in their stage blocks.

**Solution:** Add configurable retry with exponential backoff at stage level.

#### 3.1 Add retry configuration to DSL

```ruby
# lib/minigun/dsl.rb
def with_retry(max_attempts: 3, backoff: :exponential, base_delay: 0.1, max_delay: 10, &block)
  RetryWrapper.new(
    max_attempts: max_attempts,
    backoff: backoff,
    base_delay: base_delay,
    max_delay: max_delay,
    block: block
  )
end

# Usage:
processor :flaky_api do |item, output|
  with_retry(max_attempts: 3, backoff: :exponential) do
    result = api_call(item)
    output << result
  end
end
```

#### 3.2 Create RetryWrapper

```ruby
# lib/minigun/retry.rb
module Minigun
  class RetryWrapper
    BACKOFF_STRATEGIES = {
      none: ->(attempt, base, max) { 0 },
      linear: ->(attempt, base, max) { [base * attempt, max].min },
      exponential: ->(attempt, base, max) { [base * (2 ** (attempt - 1)), max].min },
      jitter: ->(attempt, base, max) { [base * (2 ** (attempt - 1)) * rand(0.5..1.5), max].min }
    }.freeze

    def initialize(max_attempts:, backoff:, base_delay:, max_delay:, block:)
      @max_attempts = max_attempts
      @backoff = BACKOFF_STRATEGIES[backoff] || BACKOFF_STRATEGIES[:exponential]
      @base_delay = base_delay
      @max_delay = max_delay
      @block = block
    end

    def call
      attempt = 0
      begin
        attempt += 1
        @block.call
      rescue StandardError => e
        if attempt < @max_attempts
          delay = @backoff.call(attempt, @base_delay, @max_delay)
          sleep(delay) if delay > 0
          retry
        else
          raise RetryExhaustedError.new(e, attempt)
        end
      end
    end
  end

  class RetryExhaustedError < Error
    attr_reader :original_error, :attempts

    def initialize(original_error, attempts)
      @original_error = original_error
      @attempts = attempts
      super("Retry exhausted after #{attempts} attempts: #{original_error.message}")
    end
  end
end
```

**Files to add:**
- `lib/minigun/retry.rb` - `RetryWrapper` and backoff strategies

**Files to modify:**
- `lib/minigun.rb` - Require retry, add `RetryExhaustedError`
- `lib/minigun/dsl.rb` - Add `with_retry` helper

---

### Phase 4: Circuit Breaker Pattern (Medium Priority)

**Problem:** Cascading failures not prevented. A failing downstream service will cause repeated failures.

**Solution:** Add circuit breaker that opens after threshold failures, prevents calls for cooldown period.

#### 4.1 Create CircuitBreaker

```ruby
# lib/minigun/circuit_breaker.rb
module Minigun
  class CircuitBreaker
    STATES = %i[closed open half_open].freeze

    attr_reader :state, :failure_count, :last_failure_time

    def initialize(
      failure_threshold: 5,
      reset_timeout: 30,
      half_open_max_calls: 3,
      on_open: nil,
      on_close: nil
    )
      @failure_threshold = failure_threshold
      @reset_timeout = reset_timeout
      @half_open_max_calls = half_open_max_calls
      @on_open = on_open
      @on_close = on_close

      @state = :closed
      @failure_count = 0
      @success_count = 0
      @last_failure_time = nil
      @mutex = Mutex.new
    end

    def call(&block)
      @mutex.synchronize do
        case @state
        when :open
          if Time.now - @last_failure_time >= @reset_timeout
            transition_to(:half_open)
          else
            raise CircuitOpenError.new(@reset_timeout - (Time.now - @last_failure_time))
          end
        when :half_open
          # Allow limited calls through
        end
      end

      begin
        result = yield
        record_success
        result
      rescue StandardError => e
        record_failure
        raise
      end
    end

    private

    def record_success
      @mutex.synchronize do
        case @state
        when :half_open
          @success_count += 1
          if @success_count >= @half_open_max_calls
            transition_to(:closed)
          end
        when :closed
          @failure_count = 0
        end
      end
    end

    def record_failure
      @mutex.synchronize do
        @failure_count += 1
        @last_failure_time = Time.now

        case @state
        when :closed
          if @failure_count >= @failure_threshold
            transition_to(:open)
          end
        when :half_open
          transition_to(:open)
        end
      end
    end

    def transition_to(new_state)
      old_state = @state
      @state = new_state

      case new_state
      when :open
        Minigun.logger.warn "[CircuitBreaker] Circuit opened after #{@failure_count} failures"
        @on_open&.call
      when :closed
        Minigun.logger.info "[CircuitBreaker] Circuit closed after successful recovery"
        @failure_count = 0
        @success_count = 0
        @on_close&.call
      when :half_open
        Minigun.logger.info "[CircuitBreaker] Circuit half-open, testing recovery"
        @success_count = 0
      end
    end
  end

  class CircuitOpenError < Error
    attr_reader :retry_after

    def initialize(retry_after)
      @retry_after = retry_after
      super("Circuit breaker is open. Retry after #{retry_after.round(1)}s")
    end
  end
end
```

#### 4.2 Add DSL integration

```ruby
# lib/minigun/dsl.rb
def circuit_breaker(name = :default, **options)
  @circuit_breakers ||= {}
  @circuit_breakers[name] ||= CircuitBreaker.new(**options)
end

# Usage:
pipeline do
  processor :external_api do |item, output|
    circuit_breaker(:api, failure_threshold: 5, reset_timeout: 30).call do
      output << api_call(item)
    end
  end
end
```

**Files to add:**
- `lib/minigun/circuit_breaker.rb`

**Files to modify:**
- `lib/minigun.rb` - Require circuit_breaker, add `CircuitOpenError`
- `lib/minigun/dsl.rb` - Add `circuit_breaker` helper

---

### Phase 5: Error Aggregation & Reporting (Lower Priority)

**Problem:** When multiple errors occur, they're logged individually with no summary.

**Solution:** Add error aggregation that collects errors and provides summary at pipeline end.

#### 5.1 Create ErrorAggregator

```ruby
# lib/minigun/error_aggregator.rb
module Minigun
  class ErrorAggregator
    def initialize
      @errors = []
      @mutex = Mutex.new
      @errors_by_stage = Hash.new { |h, k| h[k] = [] }
      @errors_by_type = Hash.new { |h, k| h[k] = [] }
    end

    def record(error, stage_name: nil, item: nil)
      @mutex.synchronize do
        entry = {
          error: error,
          stage_name: stage_name,
          item: item,
          time: Time.now,
          thread: Thread.current.object_id
        }
        @errors << entry
        @errors_by_stage[stage_name] << entry if stage_name
        @errors_by_type[error.class.name] << entry
      end
    end

    def count
      @mutex.synchronize { @errors.size }
    end

    def empty?
      count.zero?
    end

    def summary
      @mutex.synchronize do
        {
          total: @errors.size,
          by_stage: @errors_by_stage.transform_values(&:size),
          by_type: @errors_by_type.transform_values(&:size),
          first_error: @errors.first,
          last_error: @errors.last
        }
      end
    end

    def all_errors
      @mutex.synchronize { @errors.dup }
    end

    def clear
      @mutex.synchronize do
        @errors.clear
        @errors_by_stage.clear
        @errors_by_type.clear
      end
    end
  end
end
```

#### 5.2 Integrate with Pipeline

```ruby
# lib/minigun/pipeline.rb
def initialize(...)
  @error_aggregator = ErrorAggregator.new
  # ...
end

def run
  # ... execution ...
ensure
  report_errors if @error_aggregator.count > 0
end

def report_errors
  summary = @error_aggregator.summary
  Minigun.logger.warn "[Pipeline] Completed with #{summary[:total]} errors"
  summary[:by_stage].each do |stage, count|
    Minigun.logger.warn "  - #{stage}: #{count} errors"
  end
end
```

**Files to add:**
- `lib/minigun/error_aggregator.rb`

**Files to modify:**
- `lib/minigun.rb` - Require error_aggregator
- `lib/minigun/pipeline.rb` - Integrate aggregator
- `lib/minigun/stage.rb` - Report errors to aggregator

---

### Phase 6: Executor-Specific Error Handling Enhancements

#### 6.1 ThreadPoolExecutor - Add on_thread_error callback

```ruby
# lib/minigun/execution/executor.rb
class ThreadPoolExecutor
  def initialize(..., on_thread_error: nil)
    @on_thread_error = on_thread_error
    # ...
  end

  def start_worker_thread
    Thread.new do
      # ...
    rescue StandardError => e
      @on_thread_error&.call(e, Thread.current)
      raise
    end
  end
end
```

#### 6.2 IpcForkPoolExecutor - Already has restart policies ✅

Worker restart already implemented with `:never`, `:transient`, `:permanent` policies.

#### 6.3 FiberPoolExecutor - Add error callback

Similar pattern to ThreadPoolExecutor for fiber-specific errors.

#### 6.4 RactorPoolExecutor - Add error callback

```ruby
# Handle Ractor::RemoteError specifically
rescue Ractor::RemoteError => e
  @on_ractor_error&.call(e.cause, ractor)
  # ...
end
```

#### 6.5 ClusterPoolExecutor - Already has at-least-once delivery ✅

At-least-once delivery with retry already implemented.

---

### Phase 7: Dead Letter Queue Support (Lower Priority)

**Problem:** Failed items are silently dropped after error handling.

**Solution:** Add optional dead letter queue for items that fail processing.

```ruby
# lib/minigun/dsl.rb
def dead_letter_queue(queue = nil, &block)
  @dead_letter_queue = queue || DeadLetterQueue.new
  @dead_letter_handler = block
end

# Usage:
pipeline do
  dead_letter_queue do |failed_item|
    FailedItems.insert(failed_item)
  end

  processor :risky do |item, output|
    output << dangerous_operation(item)
  end
end
```

---

## Implementation Priority

### Phase 1 (High Priority - Do First)
- [ ] Hook error handling with configurable policy
- [ ] Tests for hook errors

### Phase 2 (High Priority)
- [ ] Stage-level error callbacks
- [ ] Error tracking in StageStats
- [ ] Tests for error callbacks

### Phase 3 (Medium Priority)
- [ ] RetryWrapper with backoff strategies
- [ ] Integration with DSL
- [ ] Tests for retry mechanism

### Phase 4 (Medium Priority)
- [ ] CircuitBreaker implementation
- [ ] DSL integration
- [ ] Tests for circuit breaker

### Phase 5 (Lower Priority)
- [ ] ErrorAggregator
- [ ] Pipeline integration
- [ ] Summary reporting

### Phase 6 (Lower Priority)
- [ ] Executor-specific error callbacks
- [ ] Thread/Fiber/Ractor error handlers

### Phase 7 (Optional/Future)
- [ ] Dead letter queue support

---

## Test Strategy

Each phase should include:

1. **Unit tests** for new classes (RetryWrapper, CircuitBreaker, ErrorAggregator)
2. **Integration tests** for DSL usage patterns
3. **Example files** demonstrating the feature
4. **Edge case tests**:
   - Concurrent error recording
   - Error during error handling
   - Backoff timing accuracy
   - Circuit breaker state transitions

---

## Backwards Compatibility

All features should be:
- **Opt-in** - Existing pipelines work unchanged
- **Configurable** - Default behavior matches current (log and continue)
- **Graceful** - New error classes inherit from `Minigun::Error`

---

## File Summary

**New Files:**
- `lib/minigun/retry.rb`
- `lib/minigun/circuit_breaker.rb`
- `lib/minigun/error_aggregator.rb`
- `spec/unit/retry_spec.rb`
- `spec/unit/circuit_breaker_spec.rb`
- `spec/unit/error_aggregator_spec.rb`
- `spec/integration/error_handling_spec.rb`
- `examples/150_error_callbacks.rb`
- `examples/151_retry_with_backoff.rb`
- `examples/152_circuit_breaker.rb`

**Modified Files:**
- `lib/minigun.rb` - New error classes, requires
- `lib/minigun/dsl.rb` - New DSL methods
- `lib/minigun/pipeline.rb` - Hook error handling, error aggregation
- `lib/minigun/stage.rb` - Error tracking, callbacks
- `lib/minigun/execution/executor.rb` - Executor-specific callbacks
