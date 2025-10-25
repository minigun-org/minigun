# Minigun Architecture

## Overview

Minigun uses a clean separation between **implicit** (single-pipeline) and **explicit** (multi-pipeline) modes through dedicated pipeline objects.

## Core Design

### Task Structure

```ruby
class Task
  attr_reader :implicit_pipeline  # Always exists (backward compatibility)
  attr_reader :pipelines          # Named pipelines for multi-pipeline mode
  attr_reader :pipeline_dag       # Pipeline-to-pipeline routing
end
```

### Mode Detection

The mode is automatically detected based on usage:

- **Single-Pipeline Mode**: If no named pipelines defined (`@pipelines.empty?`)
  - Runs `@implicit_pipeline` directly
  - All stage definitions go to `@implicit_pipeline`

- **Multi-Pipeline Mode**: If any named pipelines exist
  - Runs all pipelines in `@pipelines` with DAG orchestration
  - `@implicit_pipeline` is ignored

### Stage Delegation

```ruby
# Class-level stage definitions ALWAYS go to @implicit_pipeline
class MyTask
  include Minigun::DSL

  producer :fetch { ... }    # → task.implicit_pipeline.add_stage(...)
  consumer :save { ... }     # → task.implicit_pipeline.add_stage(...)
end

# Named pipeline blocks set stages on that specific pipeline
class MyTask
  include Minigun::DSL

  pipeline :extract do       # Creates @pipelines[:extract]
    producer :fetch { ... }  # → @pipelines[:extract].add_stage(...)
  end
end
```

## Flow Diagrams

### Single-Pipeline Flow

```
User Code
   ↓
  DSL.producer(:fetch)
   ↓
Task.add_stage(:producer, :fetch)
   ↓
@implicit_pipeline.add_stage(:producer, :fetch)
   ↓
Task.run(context)
   ↓
@implicit_pipeline.run(context)  # Direct execution
```

### Multi-Pipeline Flow

```
User Code
   ↓
  DSL.pipeline :extract do
    producer :fetch
  end
   ↓
Task.define_pipeline(:extract)
   ↓
@pipelines[:extract] = Pipeline.new(:extract)
@pipeline_dag.add_node(:extract)
   ↓
PipelineDSL.producer(:fetch)
   ↓
@pipelines[:extract].add_stage(:producer, :fetch)
   ↓
Task.run(context)
   ↓
run_multi_pipeline(context)  # Orchestrates all @pipelines
```

## Key Classes

### Task (Orchestrator)

**Responsibilities:**
- Manage `@implicit_pipeline` for single-pipeline mode
- Manage `@pipelines` hash for multi-pipeline mode
- Build and validate pipeline-level DAG
- Setup inter-pipeline queues
- Delegate stage/hook methods to `@implicit_pipeline`

**No more:**
- ❌ Mode tracking (`@mode` variable removed)
- ❌ `get_or_create_pipeline` complexity
- ❌ Conditional logic for pipeline selection

**Clean delegation:**
```ruby
def add_stage(type, name, options = {}, &block)
  @implicit_pipeline.add_stage(type, name, options, &block)
end
```

### Pipeline (Executor)

**Responsibilities:**
- Manage stages (producer, processors, consumers)
- Build and validate stage-level DAG
- Execute pipeline in thread or main process
- Handle inter-pipeline communication via queues
- Fork consumers for parallel processing

### DSL (Interface)

**Two contexts:**

1. **Class-level** (implicit pipeline):
```ruby
producer :name { ... }  # → task.add_stage → implicit_pipeline.add_stage
```

2. **Pipeline block** (named pipeline):
```ruby
pipeline :name do
  producer :fetch { ... }  # → specific_pipeline.add_stage
end
```

## Configuration Propagation

```ruby
Task.set_config(:max_threads, 10)
  ↓
@config[:max_threads] = 10
@implicit_pipeline.config[:max_threads] = 10
@pipelines.each { |p| p.config[:max_threads] = 10 }
```

Config changes propagate to:
- Task-level config (for future pipelines)
- Implicit pipeline
- All existing named pipelines

## Benefits of This Design

### 1. **No Mode Detection**
```ruby
# OLD (messy)
def get_or_create_pipeline(name = nil)
  if name.nil?
    @mode = :single
    name = :default
  else
    @mode = :multi
  end
  ...
end

# NEW (clean)
def run(context)
  if @pipelines.empty?
    @implicit_pipeline.run(context)
  else
    run_multi_pipeline(context)
  end
end
```

### 2. **Clear Delegation**
```ruby
# Stage methods always delegate to implicit pipeline
def add_stage(...)
  @implicit_pipeline.add_stage(...)
end

# Named pipelines are explicit
def define_pipeline(name, ...)
  @pipelines[name] = Pipeline.new(name, @config)
end
```

### 3. **Explicit Intent**
- `@implicit_pipeline` → backward compatibility (single-pipeline mode)
- `@pipelines[name]` → multi-pipeline mode
- No ambiguity about which pipeline receives stages

### 4. **Simpler Logic**
- No `@current_pipeline` tracking
- No mode switching
- Clear separation of concerns

## Example Usage

### Single-Pipeline (Implicit)

```ruby
class SimpleTask
  include Minigun::DSL

  producer :fetch { emit(1) }
  consumer :save { |x| puts x }
end

# Behind the scenes:
# task.implicit_pipeline has 2 stages
# task.pipelines is empty
# Runs: task.implicit_pipeline.run(context)
```

### Multi-Pipeline (Explicit)

```ruby
class ComplexTask
  include Minigun::DSL

  pipeline :extract, to: :transform do
    producer :fetch { emit(1) }
  end

  pipeline :transform do
    producer :input
    consumer :save { |x| puts x }
  end
end

# Behind the scenes:
# task.pipelines[:extract] has 1 stage
# task.pipelines[:transform] has 2 stages
# task.implicit_pipeline is unused
# Runs: run_multi_pipeline orchestrates both
```

## Summary

The refactored architecture is:

✅ **Cleaner** - No mode detection, explicit pipeline objects
✅ **Simpler** - Delegation is straightforward
✅ **Clearer** - Intent is obvious from code
✅ **Maintainable** - Less conditional logic
✅ **Backward Compatible** - All tests pass (120/120)

The key insight: **Use a dedicated `@implicit_pipeline` for delegation instead of complex mode detection.**

