# Error Class Standardization Plan

**Date:** 2025-11-30
**Context:** Standardizing error classes across Minigun for consistency and better error handling

---

## Philosophy: "Let it Fail" vs Defensive Error Handling

### The Question

Should Minigun adopt Elixir/Erlang's "let it fail" philosophy with supervision trees, or use defensive error handling with try/catch patterns?

### Analysis

**Erlang/Elixir's "Let it Fail" works because:**
1. Processes are isolated - one crash doesn't corrupt another's state
2. Processes are cheap - spawning replacements is fast
3. Supervision trees restart processes automatically
4. Message passing ensures no shared mutable state
5. Services are long-lived - supervision makes sense for persistent actors

**Minigun's Reality:**
1. **Batch pipelines, not services** - Minigun runs finite jobs, not long-lived actors
2. **In-memory queues** - When coordinator crashes, items are lost (no persistence)
3. **Ruby's threading model** - Threads share memory, crash isolation is weaker
4. **Fork costs** - Process forking is expensive vs Erlang's lightweight processes
5. **No preemptive scheduler** - Ruby can't interrupt runaway threads

### Conclusion: Hybrid Approach

**A full supervision tree is NOT the right abstraction for Minigun**, but we should adopt key principles:

| Elixir Principle | Minigun Adaptation |
|------------------|-------------------|
| Let processes crash | Let workers crash (IPC forks have restart policies) |
| Supervisor restarts | `WorkerMonitor` already handles this for IPC forks |
| Isolated processes | IPC forks are isolated; threads are not |
| Fail fast | Configuration errors should fail immediately |
| Error escalation | Pipeline errors should bubble up, not be swallowed |

### What This Means for Error Classes

1. **Configuration errors → Fail fast**: `ConfigurationError` subclasses should crash immediately during setup
2. **Runtime item errors → Log and continue**: Individual item failures shouldn't crash the pipeline
3. **Worker crashes → Restart policy**: Already implemented via `WorkerMonitor`
4. **Systemic failures → Circuit breaker**: Prevent cascading failures without full supervision

### What We Already Have (Supervision-like Features)

| Feature | Similar To | Location |
|---------|-----------|----------|
| IPC fork restart policies | Erlang supervisor | `WorkerMonitor` |
| `:transient`/`:permanent` | Erlang restart strategies | `IpcForkPoolExecutor` |
| `max_restarts`/`restart_window` | Erlang max_restart intensity | `WorkerMonitor` |
| At-least-once delivery | Erlang reliable messaging | `DeliveryTracker` |
| Worker heartbeat | Erlang process monitoring | `Cluster::Worker` |

### Recommendation

**Keep error handling lightweight and pragmatic:**

1. **Don't build a supervision tree** - External orchestration (K8s, systemd, Sidekiq) handles job-level restarts better
2. **Keep current worker restart** - `WorkerMonitor` provides Erlang-like restart for IPC forks
3. **Add circuit breakers** - Prevent cascading failures without complex supervision
4. **Rich error types** - Better than supervision for debugging batch jobs
5. **Error callbacks** - Let users decide how to handle failures

---

## Current State

### Existing Error Classes

| Class | Location | Purpose |
|-------|----------|---------|
| `Minigun::Error` | `lib/minigun.rb:10` | Base error class |
| `Minigun::StageNameConflict` | `lib/minigun.rb:13` | Stage name already exists |
| `Minigun::AmbiguousRoutingError` | `lib/minigun.rb:16` | Cannot resolve stage name |
| `Minigun::Errors::ClusterError` | `lib/minigun/cluster.rb:13` | Base cluster error |
| `Minigun::Cluster::ConnectionError` | `lib/minigun/cluster.rb:14` | Failed to connect |
| `Minigun::Cluster::WorkerNotFoundError` | `lib/minigun/cluster.rb:15` | Stage processor not registered |

### Issues Identified

1. **Inconsistent naming**: `StageNameConflict` vs `AmbiguousRoutingError` (suffix inconsistency)
2. **Missing error classes**: Many places raise generic `ArgumentError` or `Minigun::Error`
3. **No error hierarchy**: Flat structure makes it hard to catch groups of errors
4. **Missing attributes**: Errors don't include useful context (stage name, item, etc.)
5. **No documentation**: Error classes lack YARD docs

---

## Proposed Error Hierarchy

```
Minigun::Error (base)
├── ConfigurationError (DSL/setup errors)
│   ├── StageNameConflictError (renamed from StageNameConflict)
│   ├── AmbiguousRoutingError
│   ├── InvalidExecutorError
│   └── InvalidOptionError
│
├── ExecutionError (runtime execution errors)
│   ├── StageError (errors in stage processing)
│   │   ├── ItemProcessingError
│   │   └── RetryExhaustedError
│   ├── HookError
│   ├── TimeoutError
│   └── CircuitOpenError
│
├── PipelineError (pipeline structure errors)
│   ├── CyclicDependencyError
│   ├── UnresolvedReferenceError
│   └── SerializationError
│
└── Cluster::Error (distributed errors)
    ├── Cluster::ConnectionError
    ├── Cluster::WorkerNotFoundError
    ├── Cluster::DeliveryError
    └── Cluster::TimeoutError
```

---

## Detailed Error Class Definitions

### Base Module (`lib/minigun/errors.rb`)

```ruby
# frozen_string_literal: true

module Minigun
  # Base error class for all Minigun errors
  # @abstract
  class Error < StandardError
    # @return [Hash] Additional context about the error
    attr_reader :context

    def initialize(message = nil, **context)
      @context = context
      super(message)
    end

    # @return [String] Error message with context
    def detailed_message
      details = context.map { |k, v| "#{k}=#{v.inspect}" }.join(', ')
      details.empty? ? message : "#{message} (#{details})"
    end
  end

  # ============================================
  # Configuration Errors (DSL/setup time)
  # ============================================

  # Base class for configuration-time errors
  class ConfigurationError < Error; end

  # Raised when a stage name conflicts with another at the same pipeline level
  # @example
  #   raise StageNameConflictError.new(name: :processor, pipeline: 'main')
  class StageNameConflictError < ConfigurationError
    attr_reader :stage_name, :pipeline_name

    def initialize(message = nil, stage_name: nil, pipeline_name: nil)
      @stage_name = stage_name
      @pipeline_name = pipeline_name
      msg = message || "Stage name '#{stage_name}' already exists in pipeline '#{pipeline_name}'"
      super(msg, stage_name: stage_name, pipeline_name: pipeline_name)
    end
  end

  # Raised when routing cannot resolve an ambiguous stage name
  class AmbiguousRoutingError < ConfigurationError
    attr_reader :stage_name, :candidates

    def initialize(message = nil, stage_name: nil, candidates: [])
      @stage_name = stage_name
      @candidates = candidates
      msg = message || "Stage name '#{stage_name}' is ambiguous - found #{candidates.size} matches"
      super(msg, stage_name: stage_name, candidates: candidates)
    end
  end

  # Raised when an invalid executor type is specified
  class InvalidExecutorError < ConfigurationError
    attr_reader :executor_type, :valid_types

    def initialize(message = nil, executor_type: nil, valid_types: [])
      @executor_type = executor_type
      @valid_types = valid_types
      msg = message || "Unknown executor type: #{executor_type}. Valid: #{valid_types.join(', ')}"
      super(msg, executor_type: executor_type, valid_types: valid_types)
    end
  end

  # Raised when an invalid option is provided
  class InvalidOptionError < ConfigurationError
    attr_reader :option_name, :value, :expected

    def initialize(message = nil, option_name: nil, value: nil, expected: nil)
      @option_name = option_name
      @value = value
      @expected = expected
      msg = message || "Invalid #{option_name}: #{value.inspect}. Expected: #{expected}"
      super(msg, option_name: option_name, value: value, expected: expected)
    end
  end

  # ============================================
  # Execution Errors (runtime)
  # ============================================

  # Base class for runtime execution errors
  class ExecutionError < Error; end

  # Base class for errors occurring within a stage
  class StageError < ExecutionError
    attr_reader :stage_name

    def initialize(message = nil, stage_name: nil, **context)
      @stage_name = stage_name
      super(message, stage_name: stage_name, **context)
    end
  end

  # Raised when an item fails processing within a stage
  class ItemProcessingError < StageError
    attr_reader :item, :original_error

    def initialize(message = nil, stage_name: nil, item: nil, original_error: nil)
      @item = item
      @original_error = original_error
      msg = message || "Error processing item in stage '#{stage_name}': #{original_error&.message}"
      super(msg, stage_name: stage_name, item: item, original_error_class: original_error&.class&.name)
      set_backtrace(original_error.backtrace) if original_error
    end
  end

  # Raised when retry attempts are exhausted
  class RetryExhaustedError < StageError
    attr_reader :attempts, :original_error

    def initialize(message = nil, stage_name: nil, attempts: nil, original_error: nil)
      @attempts = attempts
      @original_error = original_error
      msg = message || "Retry exhausted after #{attempts} attempts: #{original_error&.message}"
      super(msg, stage_name: stage_name, attempts: attempts)
      set_backtrace(original_error.backtrace) if original_error
    end
  end

  # Raised when a hook fails execution
  class HookError < ExecutionError
    attr_reader :hook_type, :stage_name, :original_error

    def initialize(message = nil, hook_type: nil, stage_name: nil, original_error: nil)
      @hook_type = hook_type
      @stage_name = stage_name
      @original_error = original_error
      msg = message || "Hook #{hook_type}#{stage_name ? " for '#{stage_name}'" : ''} failed: #{original_error&.message}"
      super(msg, hook_type: hook_type, stage_name: stage_name)
      set_backtrace(original_error.backtrace) if original_error
    end
  end

  # Raised when an operation times out
  class TimeoutError < ExecutionError
    attr_reader :timeout_seconds, :operation

    def initialize(message = nil, timeout_seconds: nil, operation: nil)
      @timeout_seconds = timeout_seconds
      @operation = operation
      msg = message || "Operation '#{operation}' timed out after #{timeout_seconds}s"
      super(msg, timeout_seconds: timeout_seconds, operation: operation)
    end
  end

  # Raised when a circuit breaker is open
  class CircuitOpenError < ExecutionError
    attr_reader :circuit_name, :retry_after

    def initialize(message = nil, circuit_name: nil, retry_after: nil)
      @circuit_name = circuit_name
      @retry_after = retry_after
      msg = message || "Circuit breaker '#{circuit_name}' is open. Retry after #{retry_after&.round(1)}s"
      super(msg, circuit_name: circuit_name, retry_after: retry_after)
    end
  end

  # ============================================
  # Pipeline Structure Errors
  # ============================================

  # Base class for pipeline structure errors
  class PipelineError < Error
    attr_reader :pipeline_name

    def initialize(message = nil, pipeline_name: nil, **context)
      @pipeline_name = pipeline_name
      super(message, pipeline_name: pipeline_name, **context)
    end
  end

  # Raised when a cyclic dependency is detected in the DAG
  class CyclicDependencyError < PipelineError
    attr_reader :from_stage, :to_stage

    def initialize(message = nil, pipeline_name: nil, from_stage: nil, to_stage: nil)
      @from_stage = from_stage
      @to_stage = to_stage
      msg = message || "Circular dependency: #{from_stage} -> #{to_stage} would create a cycle"
      super(msg, pipeline_name: pipeline_name, from_stage: from_stage, to_stage: to_stage)
    end
  end

  # Raised when a stage reference cannot be resolved
  class UnresolvedReferenceError < PipelineError
    attr_reader :reference, :available_stages

    def initialize(message = nil, pipeline_name: nil, reference: nil, available_stages: [])
      @reference = reference
      @available_stages = available_stages
      msg = message || "Cannot find stage '#{reference}' in pipeline '#{pipeline_name}'"
      super(msg, pipeline_name: pipeline_name, reference: reference)
    end
  end

  # Raised when an item cannot be serialized for IPC
  class SerializationError < PipelineError
    attr_reader :item_class, :original_error

    def initialize(message = nil, item_class: nil, original_error: nil)
      @item_class = item_class
      @original_error = original_error
      msg = message || "Cannot serialize item of type #{item_class}: #{original_error&.message}"
      super(msg, item_class: item_class)
    end
  end

  # ============================================
  # Backwards Compatibility Aliases
  # ============================================

  # @deprecated Use {StageNameConflictError} instead
  StageNameConflict = StageNameConflictError
end
```

### Cluster Errors (`lib/minigun/cluster/errors.rb`)

```ruby
# frozen_string_literal: true

module Minigun
  module Cluster
    # Base error class for cluster-related errors
    class Error < Minigun::Error; end

    # Raised when connection to coordinator or worker fails
    class ConnectionError < Error
      attr_reader :uri, :original_error

      def initialize(message = nil, uri: nil, original_error: nil)
        @uri = uri
        @original_error = original_error
        msg = message || "Failed to connect to #{uri}: #{original_error&.message}"
        super(msg, uri: uri)
      end
    end

    # Raised when a required stage processor is not found on workers
    class WorkerNotFoundError < Error
      attr_reader :stage_name, :available_stages

      def initialize(message = nil, stage_name: nil, available_stages: [])
        @stage_name = stage_name
        @available_stages = available_stages
        msg = message || "No worker has processor for stage '#{stage_name}'"
        super(msg, stage_name: stage_name, available_stages: available_stages)
      end
    end

    # Raised when item delivery fails after retries
    class DeliveryError < Error
      attr_reader :item_id, :attempts, :last_error

      def initialize(message = nil, item_id: nil, attempts: nil, last_error: nil)
        @item_id = item_id
        @attempts = attempts
        @last_error = last_error
        msg = message || "Failed to deliver item #{item_id} after #{attempts} attempts"
        super(msg, item_id: item_id, attempts: attempts)
      end
    end

    # Raised when cluster operation times out
    class TimeoutError < Error
      attr_reader :operation, :timeout_seconds

      def initialize(message = nil, operation: nil, timeout_seconds: nil)
        @operation = operation
        @timeout_seconds = timeout_seconds
        msg = message || "Cluster operation '#{operation}' timed out after #{timeout_seconds}s"
        super(msg, operation: operation, timeout_seconds: timeout_seconds)
      end
    end
  end
end
```

---

## Migration Plan

### Phase 1: Create New Error Classes (Non-Breaking)

1. Create `lib/minigun/errors.rb` with new error hierarchy
2. Create `lib/minigun/cluster/errors.rb` for cluster errors
3. Add backwards-compatibility aliases (`StageNameConflict = StageNameConflictError`)
4. Update `lib/minigun.rb` to require the new files

### Phase 2: Update Raise Sites (Non-Breaking)

Replace generic errors with specific error classes:

| Current | New | Location |
|---------|-----|----------|
| `raise Minigun::Error.new("Circular dependency...")` | `raise CyclicDependencyError.new(...)` | `dag.rb:38` |
| `raise Minigun::Error.new("Cannot find stage...")` | `raise UnresolvedReferenceError.new(...)` | `pipeline.rb:222,234` |
| `raise Minigun::Error.new("Stage name collision...")` | `raise StageNameConflictError.new(...)` | `pipeline.rb:163` |
| `raise Minigun::Error.new("Unknown stage type...")` | `raise InvalidOptionError.new(...)` | `pipeline.rb:157` |
| `raise ArgumentError.new("Unknown executor...")` | `raise InvalidExecutorError.new(...)` | `executor.rb:1330` |
| `raise ArgumentError.new("Invalid restart_policy...")` | `raise InvalidOptionError.new(...)` | `worker_monitor.rb:115` |
| `raise ArgumentError.new("in_cluster requires...")` | `raise InvalidOptionError.new(...)` | `dsl.rb:378-384` |

### Phase 3: Add Context to Existing Errors

Update error messages to include more context:

```ruby
# Before
raise Minigun::Error.new("Cannot find stage: #{target}")

# After
raise UnresolvedReferenceError.new(
  pipeline_name: @name,
  reference: target,
  available_stages: @stages.keys
)
```

### Phase 4: Update Tests

1. Update specs that check for specific error types
2. Add tests for new error classes
3. Test error context attributes

---

## Implementation Order

1. **Create `lib/minigun/errors.rb`** - All error classes with attributes
2. **Create `lib/minigun/cluster/errors.rb`** - Cluster-specific errors
3. **Update `lib/minigun.rb`** - Require new files, keep aliases
4. **Update raise sites** - One file at a time:
   - `dag.rb`
   - `pipeline.rb`
   - `stage_registry.rb`
   - `dsl.rb`
   - `executor.rb`
   - `worker_monitor.rb`
   - `cluster.rb`
5. **Add unit tests** for error classes
6. **Update documentation** - YARD docs for all errors

---

## Files to Create

- `lib/minigun/errors.rb`
- `lib/minigun/cluster/errors.rb`
- `spec/unit/errors_spec.rb`

## Files to Modify

- `lib/minigun.rb` - Remove inline error classes, add requires
- `lib/minigun/cluster.rb` - Remove inline error classes, add require
- `lib/minigun/dag.rb` - Use `CyclicDependencyError`
- `lib/minigun/pipeline.rb` - Use specific error types
- `lib/minigun/stage_registry.rb` - Use `StageNameConflictError` with context
- `lib/minigun/dsl.rb` - Use `InvalidOptionError`
- `lib/minigun/execution/executor.rb` - Use `InvalidExecutorError`
- `lib/minigun/execution/worker_monitor.rb` - Use `InvalidOptionError`
- `lib/minigun/queue_wrappers.rb` - Use `SerializationError`

---

## Backwards Compatibility

- `StageNameConflict` aliased to `StageNameConflictError`
- All new errors inherit from existing base classes
- Existing `rescue Minigun::Error` still catches everything
- No breaking changes to public API

---

## Benefits

1. **Specific error handling**: `rescue Minigun::ConfigurationError` vs `rescue Minigun::ExecutionError`
2. **Rich context**: `error.stage_name`, `error.pipeline_name`, `error.original_error`
3. **Better debugging**: `error.detailed_message` includes all context
4. **Type safety**: IDE/linter can suggest error types
5. **Documentation**: YARD docs for each error class
