# Pipeline Inheritance Implementation Plan

## Status: IMPLEMENTED

This plan has been implemented. See `docs/architecture/pipeline_inheritance.md` for the final architecture.

## Summary

Pipeline inheritance in Minigun follows these simple rules:

| Scenario | Behavior |
|----------|----------|
| Unnamed `pipeline do` | Stages go on `root_pipeline` (shared) |
| Named `pipeline :name do` | Creates `PipelineStage` wrapper |
| Same named pipeline declared twice | Second extends the first |
| Child class | Inherits parent's blocks, can add more |

## Implementation Details

### Files Modified

1. **`lib/minigun/dsl.rb`**
   - Added `:source` field to pipeline definition blocks (`:self` or `:inherited`)
   - Updated `inherited` hook to mark parent blocks as `:inherited`
   - Refactored `_evaluate_pipeline_blocks!` into helper methods:
     - `_evaluate_block_on_root` - evaluates unnamed block on root_pipeline
     - `_create_named_pipeline` - creates new PipelineStage
     - `_extend_named_pipeline` - adds stages to existing named pipeline

2. **`spec/integration/pipeline_inheritance_spec.rb`** (NEW)
   - Comprehensive integration tests for all inheritance scenarios

3. **`docs/architecture/pipeline_inheritance.md`** (NEW)
   - Architecture documentation

### Key Code Changes

```ruby
# Pipeline block storage now includes source tracking
def pipeline(name = nil, options = {}, &block)
  @_pipeline_definition_blocks ||= []
  @_pipeline_definition_blocks << {
    name: name,
    options: options,
    block: block,
    source: :self
  }
end

# Inherited blocks are marked
def base.inherited(subclass)
  parent_blocks = (@_pipeline_definition_blocks || []).map do |entry|
    entry.dup.merge(source: :inherited)
  end
  subclass.instance_variable_set(:@_pipeline_definition_blocks, parent_blocks)
end

# Evaluation is clean and simple
def _evaluate_pipeline_blocks!
  unnamed_blocks.each { |entry| _evaluate_block_on_root(entry) }

  named_blocks.each do |entry|
    if created_pipelines[entry[:name]]
      _extend_named_pipeline(entry[:name], entry)
    else
      created_pipelines[entry[:name]] = _create_named_pipeline(entry[:name], entry)
    end
  end
end
```

## Test Coverage

16 integration tests covering:
- Single unnamed pipeline
- Multiple unnamed pipelines in same class
- Named pipeline extension (same class)
- Inheritance with unnamed pipelines
- Inheritance with named pipelines
- Multi-level inheritance (grandparent → parent → child)
- Mixed named and unnamed pipelines
- Source tracking verification
- Edge cases (empty pipeline, no pipeline, child skipping stages)

## Design Decisions Made

### 1. Unnamed Pipelines Always Go on Root

**Decision**: All unnamed pipeline blocks evaluate on `root_pipeline`, regardless of how many there are.

**Rationale**: This allows named pipelines to route to stages defined in unnamed blocks. Isolating them would break routing.

### 2. No Hoisting

**Decision**: Skip the "hoist single pipeline to root" optimization.

**Rationale**: Adds complexity without clear benefit. The system works fine with or without nested pipeline wrappers.

### 3. Source Tracking for Debugging

**Decision**: Track `:source` as `:self` or `:inherited` on each block.

**Rationale**: Enables debugging and potentially future features (e.g., only inherited blocks can be overridden).

### 4. Named Pipeline Extension is Implicit

**Decision**: Declaring a named pipeline that already exists extends it rather than replacing.

**Rationale**: Matches inheritance semantics - child adds to parent, doesn't replace.

## What Was NOT Implemented

1. **Stage name conflict detection** - Redeclaring a stage with same name is allowed (use with caution)
2. **Pipeline hoisting** - Single pipeline remains wrapped if named
3. **Isolated unnamed pipelines** - Originally considered, rejected for simplicity

## Migration Notes

This is a **non-breaking change**. Existing code with:
- Single unnamed pipeline: works unchanged
- Named pipelines: works unchanged
- Simple inheritance: works unchanged

New capabilities:
- Multiple unnamed pipelines (stages coexist on root)
- Named pipeline extension
- Multi-level inheritance with rerouting
