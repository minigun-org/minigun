# Pipeline Inheritance Architecture

## Overview

Pipeline inheritance allows child classes to extend parent pipelines, enabling code reuse and compositional patterns. This document describes the architecture for a clean, predictable pipeline inheritance system.

## Goals

1. **Predictable behavior** - Clear rules for how pipelines combine
2. **Composability** - Allow extending parent pipelines without modification
3. **Simplicity** - Avoid overly complex merging rules
4. **Backwards compatibility** - Existing single-pipeline behavior works unchanged

## Design Rules

After analyzing various approaches, the implemented rules are:

1. **Unnamed pipelines** - All stages evaluate directly on `root_pipeline` (shared/combined)
2. **Named pipelines** - Create `PipelineStage` wrappers; same name = extend existing
3. **Inheritance** - Child inherits parent's blocks (marked as `:inherited`), can extend them

### Key Insight

Unnamed pipelines provide "shared" stages on the root that named pipelines can route to/from. This enables patterns like:

```ruby
pipeline do
  processor :transform ...  # Shared on root
  consumer :collect ...     # Shared on root
end

pipeline :producer, to: :transform do
  producer :source ...      # Named pipeline routes to shared stage
end
```

## Architecture

### Pipeline Definition Storage

```ruby
# In ClassMethods
def pipeline(name = nil, options = {}, &block)
  @_pipeline_definition_blocks ||= []
  @_pipeline_definition_blocks << {
    name: name,
    options: options,
    block: block,
    source: :self  # or :inherited
  }
end
```

### Inheritance Mechanism

When a subclass is created:

```ruby
def base.inherited(subclass)
  super if defined?(super)

  # Copy parent's task configuration (not pipeline - rebuilt from blocks)
  parent_task = _minigun_task
  new_task = Minigun::Task.new(config: parent_task.config.dup)
  subclass._minigun_task = new_task

  # Inherit pipeline blocks with source tracking
  parent_blocks = (@_pipeline_definition_blocks || []).map do |entry|
    entry.dup.merge(source: :inherited)
  end
  subclass.instance_variable_set(:@_pipeline_definition_blocks, parent_blocks)
end
```

### Block Evaluation Logic

At instance creation (`_evaluate_pipeline_blocks!`):

```ruby
def _evaluate_pipeline_blocks!
  return if @_pipeline_blocks_evaluated
  @_pipeline_blocks_evaluated = true

  @_minigun_task = Minigun::Task.new(config: self.class._minigun_task.config.dup)

  blocks = self.class._pipeline_definition_blocks
  return if blocks.empty?

  unnamed_blocks = blocks.select { |b| b[:name].nil? }
  named_blocks = blocks.reject { |b| b[:name].nil? }

  created_pipelines = {}

  # Unnamed pipelines go on root_pipeline (shared stages)
  unnamed_blocks.each do |entry|
    _evaluate_block_on_root(entry)
  end

  # Named pipelines create/extend PipelineStages
  named_blocks.each do |entry|
    name = entry[:name]
    if created_pipelines[name]
      _extend_named_pipeline(name, entry)
    else
      created_pipelines[name] = _create_named_pipeline(name, entry)
    end
  end
end
```

## Examples

### Example 1: Single Unnamed Pipeline

```ruby
class BaseTask
  include Minigun::DSL

  pipeline do
    producer :source do |output|
      [1, 2, 3].each { |n| output << n }
    end

    consumer :collect do |n|
      @results << n
    end
  end
end
```

**Result**: Stages added directly to `root_pipeline`.

### Example 2: Child Extends Parent

```ruby
class ExtendedTask < BaseTask
  pipeline do
    processor :double do |n, output|
      output << n * 2
    end

    # Reroute to insert processor
    reroute_stage :source, to: :double
    reroute_stage :double, to: :collect
  end
end
```

**Result**: Child inherits parent stages, adds `:double`, and reroutes.

### Example 3: Named Pipeline Extension

```ruby
class NamedBase
  include Minigun::DSL

  pipeline :main do
    producer :source do |output|
      [1, 2, 3].each { |n| output << n }
    end

    consumer :collect do |n|
      @results << n
    end
  end
end

class ExtendedNamed < NamedBase
  # Extend the :main pipeline by declaring it again
  pipeline :main do
    processor :transform do |n, output|
      output << n + 100
    end

    reroute_stage :source, to: :transform
    reroute_stage :transform, to: :collect
  end
end
```

**Result**: The `:main` pipeline has all stages from parent plus child's additions.

### Example 4: Mixed Named and Unnamed

```ruby
class MixedPipeline
  include Minigun::DSL

  pipeline do
    # Shared stages on root
    processor :transform do |item, output|
      output << item * 10
    end

    consumer :collect do |item|
      @results << item
    end
  end

  # Named pipeline routes to shared stage
  pipeline :producer, to: :transform do
    producer :source do |output|
      [1, 2, 3].each { |n| output << n }
    end

    consumer :forward do |item, output|
      output << item
    end
  end
end
```

**Result**: Named pipeline produces items that flow to shared `:transform` stage.

### Example 5: Multiple Unnamed Pipelines

```ruby
class MultiPipeline
  include Minigun::DSL

  pipeline do
    producer :source_a do |output|
      output << "A"
    end
    consumer :collect_a do |item|
      @results_a << item
    end
  end

  pipeline do
    producer :source_b do |output|
      output << "B"
    end
    consumer :collect_b do |item|
      @results_b << item
    end
  end
end
```

**Result**: Both pipelines' stages go on root. They run as independent flows within the same root pipeline.

## Edge Cases

### Stage Name Conflicts

When extending a pipeline (named or through inheritance), child can:
- Add new stages (no conflict)
- Reference parent stages in `reroute_stage`
- Redefine a stage with same name (replaces parent's - use with caution)

### Routing Across Inheritance

Child can reroute parent's stages:

```ruby
class Parent
  pipeline do
    producer :a ...
    consumer :c ...
  end
end

class Child < Parent
  pipeline do
    processor :b do |item, output|
      output << item.upcase
    end

    reroute_stage :a, to: :b
    reroute_stage :b, to: :c
  end
end
```

### Empty Pipelines

An empty pipeline block is valid (no-op):

```ruby
pipeline do
  # Empty - no stages added
end
```

## Testing

See `spec/integration/pipeline_inheritance_spec.rb` for comprehensive tests covering:
- Single unnamed pipeline
- Multiple unnamed pipelines
- Named pipeline extension
- Inheritance with unnamed pipelines
- Inheritance with named pipelines
- Multi-level inheritance
- Mixed named and unnamed pipelines
- Source tracking
- Edge cases

## Why Not Isolate Multiple Unnamed Pipelines?

An earlier design considered isolating multiple unnamed pipelines in separate `PipelineStage` wrappers. This was rejected because:

1. **Breaks routing** - Named pipelines can't route to stages inside isolated unnamed pipelines
2. **Inconsistent** - Single unnamed works one way, multiple works another
3. **Confusing** - No clear mental model for when isolation happens

The current design is simpler: **unnamed = shared on root, named = wrapped**.
