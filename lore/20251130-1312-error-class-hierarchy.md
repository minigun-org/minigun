# Error Class Hierarchy

## Overview

Minigun uses a structured error hierarchy under the `Minigun::Errors` namespace. All errors inherit from `Minigun::Errors::BaseError`, which extends `StandardError` with context tracking capabilities.

## Error Namespace Structure

```
Minigun::Errors::
├── BaseError                    # Base class with context support
├── ConfigurationError           # Configuration/setup errors
│   ├── StageNameConflict        # Duplicate stage name in pipeline
│   ├── AmbiguousRouting         # Multiple stages match a reference
│   └── InvalidOption            # Invalid option value
├── PipelineError                # Pipeline structure errors
│   ├── CyclicDependency         # DAG cycle detected
│   ├── UnresolvedReference      # Stage reference not found
│   └── SerializationFailed      # IPC serialization failure
├── ExecutionError               # Runtime execution errors
│   ├── StageError               # Stage-specific errors
│   │   ├── ItemProcessingFailed # Item processing failed
│   │   └── RetryExhausted       # All retries exhausted
│   ├── HookFailed               # Hook execution failed
│   └── CircuitBreakerOpen       # Circuit breaker triggered
└── ClusterError                 # Distributed cluster errors
    ├── ClusterConnectionFailed  # Worker connection failed
    ├── ClusterWorkerNotFound    # No worker for stage
    ├── ClusterDeliveryFailed    # Item delivery failed
    └── ClusterTimedOut          # Operation timeout
```

## Naming Conventions

- **Base/category classes** use `Error` suffix: `BaseError`, `ConfigurationError`, `PipelineError`, `ExecutionError`, `StageError`, `ClusterError`
- **Specific errors** use descriptive names without `Error` suffix, describing what happened:
  - Past tense for failures: `SerializationFailed`, `ItemProcessingFailed`, `ClusterConnectionFailed`, `ClusterDeliveryFailed`, `HookFailed`
  - State descriptions: `RetryExhausted`, `CircuitBreakerOpen`, `ClusterTimedOut`
  - Condition descriptions: `StageNameConflict`, `AmbiguousRouting`, `CyclicDependency`, `UnresolvedReference`, `InvalidOption`, `ClusterWorkerNotFound`

## BaseError Context System

All errors support structured context via keyword arguments:

```ruby
class BaseError < StandardError
  attr_reader :context

  def initialize(message = nil, **context)
    @context = context
    super(message)
  end

  def detailed_message(...)
    return message if context.empty?
    details = context.map { |k, v| "#{k}=#{v.inspect}" }.join(', ')
    "#{message} (#{details})"
  end
end
```

## Error Attributes

Each error class defines accessor methods for its context keys:

```ruby
# StageNameConflict
error.stage_name      # Symbol - the conflicting name
error.pipeline_name   # String - pipeline where conflict occurred

# AmbiguousRouting
error.stage_name      # Symbol - the ambiguous name
error.candidates      # Array - list of matching stages

# InvalidOption
error.option_name     # Symbol - the invalid option
error.value           # Object - the invalid value provided
error.expected        # String - description of valid values

# CyclicDependency
error.from_stage      # Symbol/Stage - source of cycle edge
error.to_stage        # Symbol/Stage - target of cycle edge

# UnresolvedReference
error.reference       # Symbol - the unresolved reference
error.available_stages # Array - list of available stages
error.pipeline_name   # String - pipeline context

# ItemProcessingFailed
error.stage_name      # Symbol - stage where error occurred
error.item            # Object - the item that failed
error.original_error  # Exception - the underlying error

# ClusterConnectionFailed
error.uri             # String - the worker URI
error.original_error  # Exception - connection error

# ClusterWorkerNotFound
error.stage_name      # Symbol - the missing stage
error.available_stages # Array - stages worker can handle
```

## Usage Examples

### Raising Errors

```ruby
# Configuration errors
raise Errors::StageNameConflict.new(
  stage_name: :processor,
  pipeline_name: 'main'
)

raise Errors::InvalidOption.new(
  option_name: :restart_policy,
  value: :invalid,
  expected: ':never, :transient, :permanent'
)

# Pipeline errors
raise Errors::CyclicDependency.new(
  from_stage: stage_c,
  to_stage: stage_a
)

# Cluster errors
raise Errors::ClusterWorkerNotFound.new(
  stage_name: :missing,
  available_stages: [:processor, :consumer]
)
```

### Catching Errors

```ruby
begin
  pipeline.run
rescue Minigun::Errors::StageNameConflict => e
  puts "Duplicate stage: #{e.stage_name} in #{e.pipeline_name}"
rescue Minigun::Errors::ConfigurationError => e
  puts "Configuration error: #{e.message}"
rescue Minigun::Errors::BaseError => e
  puts "Minigun error: #{e.detailed_message}"
end
```

## File Locations

- Error definitions: `lib/minigun/errors.rb`
- Error tests: `spec/unit/errors_spec.rb`, `spec/integration/errors_spec.rb`
- Documentation: `docs/guides/errors.md`
