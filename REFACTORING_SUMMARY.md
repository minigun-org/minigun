# Refactoring Summary: root_pipeline Unification

## Changes Made

### 1. Renamed `implicit_pipeline` to `root_pipeline`
- More accurate name - it's the root of the stage/pipeline tree, not just "implicit"
- Updated throughout codebase: `lib/minigun/task.rb`, `lib/minigun/dsl.rb`, `lib/minigun/runner.rb`
- Updated all specs and examples

### 2. Eliminated Separate `@pipelines` Hash
**Before:**
- `@root_pipeline` (implicit/default pipeline)
- `@pipelines = {}` (separate hash for named pipelines)
- `@pipeline_dag` (separate DAG for pipeline routing)

**After:**
- `@root_pipeline` - contains ALL stages, including PipelineStage objects
- `pipelines()` - method that extracts PipelineStage objects from `root_pipeline.stages`
- `pipeline_dag()` - method that returns `root_pipeline.dag`

### 3. Unified Pipeline/Stage Representation
Pipelines are now just special stages (PipelineStage) within the root pipeline:
- `define_pipeline` adds a `PipelineStage` to `@root_pipeline.stages`
- Routing (`to:`, `from:`) is handled in `@root_pipeline.dag`
- No distinction between "nested" and "multi" pipelines at the storage level

### 4. Improved DAG Management
- Created `@pipeline_only_dag` in `build_pipeline_routing!` to isolate pipeline-to-pipeline routing
- Filters root DAG edges to only include PipelineStage objects
- Prevents nested pipelines (without routing) from interfering with multi-pipeline queue setup

## Benefits

1. **Conceptual Simplicity**: Pipelines ARE stages - no special cases
2. **Unified Storage**: Everything lives in `root_pipeline.stages`
3. **Consistent Routing**: All routing uses the same DAG
4. **Easier Mixed Routing**: Stage-to-pipeline and pipeline-to-stage routing can work in the same DAG

## Test Status

**Before refactoring**: 236 examples, 0 failures (excluding mixed routing tests)
**After refactoring**: 236 examples, 2 failures (nested pipeline issues need fixing)

The remaining issues are with nested pipelines that don't have explicit `to:`/`from:` routing.

## Next Steps

1. Fix nested pipeline execution logic
2. Implement mixed pipeline/stage routing (16 pending tests)
3. Ensure all scenarios work transparently

