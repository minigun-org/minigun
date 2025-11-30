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

## Constructor Design Pattern

Two patterns are used for error constructors:

### Pattern 1: Required Message (explicit context)
When errors need custom, context-specific messages:
```ruby
def initialize(message, required_attr:, optional_attr: nil)
```
- Message is **required** (no default)
- Caller must provide a descriptive message

### Pattern 2: Auto-generated Message (structured context)
When errors can generate good messages from attributes:
```ruby
def initialize(required_attr:, optional_attr: nil)
```
- No message parameter
- Message is auto-generated from required attributes

## Error Signatures

### Errors with Required Message
```ruby
UnresolvedReference.new(message, reference:, pipeline_name: nil, available_stages: [])
```

### Errors with Auto-generated Message
```ruby
StageNameConflict.new(stage_name:, pipeline_name:)
AmbiguousRouting.new(stage_name:, candidates:)
InvalidOption.new(option_name:, value: nil, expected: nil)
CyclicDependency.new(from_stage:, to_stage:, pipeline_name: nil)
SerializationFailed.new(item_class:, original_error: nil)
ItemProcessingFailed.new(stage_name:, original_error:, item: nil)
RetryExhausted.new(attempts:, original_error:, stage_name: nil)
HookFailed.new(hook_type:, original_error:, stage_name: nil)
CircuitBreakerOpen.new(circuit_name:, retry_after: nil)
ClusterConnectionFailed.new(uri:, original_error:)
ClusterWorkerNotFound.new(stage_name:, available_stages: [])
ClusterDeliveryFailed.new(item_id:, attempts:, last_error: nil)
ClusterTimedOut.new(operation:, timeout_seconds:)
```

### Base Classes (optional message for one-off errors)
```ruby
BaseError.new(message = nil, **context)
ConfigurationError.new(message = nil, **context)
PipelineError.new(message = nil, pipeline_name: nil, **context)
ExecutionError.new(message = nil, **context)
StageError.new(message = nil, stage_name: nil, **context)
ClusterError.new(message = nil, **context)
```

## Naming Conventions

- **Base/category classes** use `Error` suffix: `BaseError`, `ConfigurationError`, `PipelineError`, `ExecutionError`, `StageError`, `ClusterError`
- **Specific errors** use descriptive names without `Error` suffix:
  - Past tense for failures: `SerializationFailed`, `ItemProcessingFailed`, `ClusterConnectionFailed`, `ClusterDeliveryFailed`, `HookFailed`
  - State descriptions: `RetryExhausted`, `CircuitBreakerOpen`, `ClusterTimedOut`
  - Condition descriptions: `StageNameConflict`, `AmbiguousRouting`, `CyclicDependency`, `UnresolvedReference`, `InvalidOption`, `ClusterWorkerNotFound`

## Usage Examples

### Raising Errors (auto-generated message)
```ruby
raise Errors::StageNameConflict.new(
  stage_name: :processor,
  pipeline_name: 'main'
)
# => "Stage name 'processor' already exists in pipeline 'main'"

raise Errors::InvalidOption.new(
  option_name: :restart_policy,
  value: :invalid,
  expected: ':never, :transient, :permanent'
)
# => "Invalid restart_policy: :invalid. Expected: :never, :transient, :permanent"
```

### Raising Errors (required message)
```ruby
raise Errors::UnresolvedReference.new(
  "Stage 'missing' not found for rerouting",
  reference: :missing,
  pipeline_name: 'main',
  available_stages: [:a, :b, :c]
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
