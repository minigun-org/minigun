# Error Handling Guide

Minigun provides a comprehensive error hierarchy to help you handle failures gracefully.
All errors inherit from `Minigun::Error`, which inherits from `StandardError`.

## Error Hierarchy Overview

```
Minigun::Error
├── ConfigurationError (DSL/setup time errors)
│   ├── StageNameConflictError
│   ├── AmbiguousRoutingError
│   └── InvalidOptionError
├── PipelineError (pipeline structure errors)
│   ├── CyclicDependencyError
│   ├── UnresolvedReferenceError
│   └── SerializationError
├── ExecutionError (runtime errors)
│   ├── StageError
│   │   ├── ItemProcessingError
│   │   └── RetryExhaustedError
│   ├── HookError
│   └── CircuitBreakerOpenError
└── ClusterError (distributed errors)
    ├── ClusterConnectionError
    ├── ClusterWorkerNotFoundError
    ├── ClusterDeliveryError
    └── ClusterTimeoutError
```

**Note:** For backwards compatibility, cluster errors are also available under the `Minigun::Cluster` module
(e.g., `Minigun::Cluster::Error`, `Minigun::Cluster::ConnectionError`, etc.).

## Base Error Class

All Minigun errors support context attributes:

```ruby
begin
  pipeline.run
rescue Minigun::Error => e
  puts e.message           # Basic error message
  puts e.detailed_message  # Message with context: "message (key=value, ...)"
  puts e.context           # Hash of context attributes
end
```

## Configuration Errors

These errors occur during pipeline definition, before execution starts.

### StageNameConflictError

Raised when you try to create two stages with the same name in the same pipeline.

```ruby
pipeline do
  processor :transform do |item, output|
    output << item
  end

  # This raises StageNameConflictError
  processor :transform do |item, output|
    output << item * 2
  end
end
```

**Attributes:**
- `stage_name` - The conflicting stage name
- `pipeline_name` - The pipeline where the conflict occurred

**Solution:** Use unique stage names within each pipeline. Same names are allowed in different nested pipelines.

### AmbiguousRoutingError

Raised when routing cannot resolve an ambiguous stage name in nested pipelines.

```ruby
pipeline do
  nested_pipeline :a do
    processor :transform do |item, output|
      output << item
    end
  end

  nested_pipeline :b do
    processor :transform do |item, output|
      output << item
    end
  end

  # Routing to :transform is ambiguous - exists in both :a and :b
  processor :sender, to: :transform do |item, output|
    output << item
  end
end
```

**Attributes:**
- `stage_name` - The ambiguous stage name
- `candidates` - List of matching stage paths

**Solution:** Use fully qualified paths like `pipeline_a.transform` or restructure your nested pipelines.

### InvalidOptionError

Raised when an invalid option value is provided to DSL methods.

```ruby
# Invalid executor type
in_context(:invalid_type) do
  processor :work do |item, output|
    output << item
  end
end

# Invalid restart policy
in_ipc_forks(4, restart_policy: :invalid) do
  processor :work do |item, output|
    output << item
  end
end

# Invalid delivery mode
in_cluster(worker_uris: [...], delivery_mode: :invalid) do
  processor :work do |item, output|
    output << item
  end
end
```

**Attributes:**
- `option_name` - The option that has an invalid value
- `value` - The invalid value provided
- `expected` - Description of expected values

## Pipeline Errors

These errors relate to the pipeline's DAG structure and routing.

### CyclicDependencyError

Raised when a routing configuration would create a cycle in the pipeline.

```ruby
pipeline do
  processor :a, to: :b do |item, output|
    output << item
  end

  processor :b, to: :c do |item, output|
    output << item
  end

  # This raises CyclicDependencyError - creates a cycle: a -> b -> c -> a
  processor :c, to: :a do |item, output|
    output << item
  end
end
```

**Attributes:**
- `pipeline_name` - The pipeline where the cycle was detected
- `from_stage` - The source stage of the edge causing the cycle
- `to_stage` - The target stage of the edge causing the cycle

**Solution:** Review your routing configuration and ensure data flows in one direction (DAG).

### UnresolvedReferenceError

Raised when a stage references a non-existent target.

```ruby
pipeline do
  producer :source, to: :nonexistent do |output|
    output << 1
  end
end
```

**Attributes:**
- `pipeline_name` - The pipeline name
- `reference` - The unresolved stage reference
- `available_stages` - List of valid stage names

**Solution:** Check spelling and ensure the target stage is defined before referencing it.

### SerializationError

Raised when an item cannot be serialized for IPC communication (forks, cluster).

```ruby
in_ipc_forks(4) do
  processor :work do |item, output|
    # Raises SerializationError - lambdas can't be marshaled
    output << lambda { puts "hello" }
  end
end
```

**Attributes:**
- `item_class` - The class name of the item that couldn't be serialized
- `original_error` - The underlying serialization error

**Solution:** Only pass serializable objects (primitives, arrays, hashes, custom classes) through IPC boundaries. Avoid Procs, lambdas, and IO objects.

## Execution Errors

These errors occur during pipeline execution.

### StageError

Base class for errors occurring within a specific stage.

**Attributes:**
- `stage_name` - The stage where the error occurred

### ItemProcessingError

Raised when an item fails processing within a stage. Wraps the original error with context.

**Attributes:**
- `stage_name` - The stage where the error occurred
- `item` - The item that failed to process
- `original_error` - The original exception

**Note:** The backtrace is preserved from the original error for debugging.

### RetryExhaustedError

Raised when retry attempts are exhausted for an operation.

**Attributes:**
- `stage_name` - The stage where retries were exhausted
- `attempts` - Number of attempts made
- `original_error` - The last error before giving up

### HookError

Raised when a hook (before/after callbacks) fails execution.

```ruby
pipeline do
  before_fork do
    raise "Hook failed"  # Raises HookError
  end

  in_ipc_forks(4) do
    processor :work do |item, output|
      output << item
    end
  end
end
```

**Attributes:**
- `hook_type` - The hook type (`:before`, `:after`, `:before_fork`, etc.)
- `stage_name` - The stage name if this is a stage hook (optional)
- `original_error` - The original error from the hook

### CircuitBreakerOpenError

Raised when a circuit breaker is open and rejecting calls.

**Attributes:**
- `circuit_name` - The circuit breaker identifier
- `retry_after` - Seconds until the circuit may close

## Cluster Errors

These errors occur in distributed cluster mode. All cluster errors inherit from `ClusterError`.

### ClusterConnectionError

Raised when connection to a coordinator or worker fails.

**Attributes:**
- `uri` - The DRb URI that failed
- `original_error` - The underlying connection error

### ClusterWorkerNotFoundError

Raised when a worker doesn't have a processor for the requested stage.

**Attributes:**
- `stage_name` - The missing stage name
- `available_stages` - List of stages the worker can handle

### ClusterDeliveryError

Raised when an item cannot be delivered to workers after all retry attempts.

**Attributes:**
- `item_id` - Identifier for the failed item
- `attempts` - Number of delivery attempts
- `last_error` - The last error before giving up

### ClusterTimeoutError

Raised when an operation times out (e.g., waiting for workers).

**Attributes:**
- `operation` - Description of what timed out
- `timeout_seconds` - The timeout duration

## Error Handling Patterns

### Catching All Minigun Errors

```ruby
begin
  pipeline.run
rescue Minigun::Error => e
  logger.error "Pipeline failed: #{e.detailed_message}"
end
```

### Catching Specific Error Categories

```ruby
begin
  pipeline.run
rescue Minigun::ConfigurationError => e
  # DSL/setup errors - fix your pipeline definition
  raise
rescue Minigun::ExecutionError => e
  # Runtime errors - may be recoverable
  logger.warn "Execution error: #{e.message}"
  # Implement recovery logic
rescue Minigun::ClusterError => e
  # Distributed errors - retry or fail over
  logger.error "Cluster error: #{e.message}"
end
```

### Handling Specific Errors

```ruby
begin
  pipeline.run
rescue Minigun::UnresolvedReferenceError => e
  puts "Unknown stage '#{e.reference}'. Available: #{e.available_stages.join(', ')}"
rescue Minigun::StageNameConflictError => e
  puts "Duplicate stage '#{e.stage_name}' in pipeline '#{e.pipeline_name}'"
rescue Minigun::CircuitBreakerOpenError => e
  puts "Circuit '#{e.circuit_name}' is open, retry in #{e.retry_after}s"
end
```

## Best Practices

1. **Let configuration errors fail fast** - Don't rescue `ConfigurationError` in production; fix the pipeline definition.

2. **Handle execution errors gracefully** - Use try/catch around `pipeline.run` to handle runtime failures.

3. **Use error context** - Access `error.context` or `error.detailed_message` for debugging information.

4. **Log original errors** - For wrapped errors like `ItemProcessingError`, log `original_error` for the full stack trace.

5. **Design for failure** - In cluster mode, use `delivery_mode: :at_least_once` for critical data and handle `DeliveryError` appropriately.
