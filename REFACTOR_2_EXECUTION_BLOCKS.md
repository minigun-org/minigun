# Refactor 2: Execution Block Syntax

## Goal
Replace strategy-based execution with clear execution block syntax: `threads do`, `processes do`, `process_per_batch`, etc.

---

## Current State

```ruby
class MyPipeline
  include Minigun::DSL

  max_threads 50
  max_processes 4

  producer :gen do
    emit(data)
  end

  processor :work, strategy: :threaded do |item|
    emit(item * 2)
  end

  spawn_fork :heavy do |item|
    emit(process(item))
  end

  consumer :save, strategy: :threaded do |item|
    store(item)
  end
end
```

---

## Target State

```ruby
class MyPipeline
  include Minigun::DSL

  pipeline do
    producer :gen do
      emit(data)
    end

    threads(50) do
      processor :work do |item|
        emit(item * 2)
      end
    end

    batch 1000

    process_per_batch(max: 4) do
      processor :heavy do |item|
        emit(process(item))
      end
    end

    consumer :save do |item|
      store(item)
    end
  end
end
```

---

## New API Summary

```ruby
# Execution blocks (reused pools)
threads(N) do ... end
processes(N) do ... end
ractors(N) do ... end

# Per-batch execution (spawn new each time)
thread_per_batch(max: N) do ... end
process_per_batch(max: N) do ... end
ractor_per_batch(max: N) do ... end

# Batching
batch N
```

---

## Step-by-Step Execution Plan

### Phase 1: Add New DSL Methods (Parallel with Old)

**Duration**: 1 week

#### Step 1.1: Add Execution Block Methods
**File**: `lib/minigun/dsl.rb`

```ruby
module Minigun
  module DSL
    # Execution block methods (instance-level)

    def threads(pool_size = 5, &block)
      with_execution_context(type: :thread, pool_size: pool_size) do
        instance_eval(&block)
      end
    end

    def processes(pool_size = 2, &block)
      with_execution_context(type: :process, pool_size: pool_size) do
        instance_eval(&block)
      end
    end

    def ractors(pool_size = 4, &block)
      with_execution_context(type: :ractor, pool_size: pool_size) do
        instance_eval(&block)
      end
    end

    def thread_per_batch(max: 10, &block)
      with_execution_context(type: :thread, mode: :per_batch, max: max) do
        instance_eval(&block)
      end
    end

    def process_per_batch(max: 4, &block)
      with_execution_context(type: :process, mode: :per_batch, max: max) do
        instance_eval(&block)
      end
    end

    def ractor_per_batch(max: 8, &block)
      with_execution_context(type: :ractor, mode: :per_batch, max: max) do
        instance_eval(&block)
      end
    end

    def batch(size)
      # Add accumulator stage
      accumulator :_batch, max_size: size
    end

    private

    def with_execution_context(context_config, &block)
      # Push context onto stack
      @_execution_context_stack ||= []
      @_execution_context_stack.push(context_config)

      # Evaluate block
      yield

      # Pop context
      @_execution_context_stack.pop
    end

    def current_execution_context
      @_execution_context_stack&.last || { type: :thread, pool_size: 5 }
    end
  end
end
```

**Tests**: `spec/unit/dsl/execution_blocks_spec.rb`
```ruby
RSpec.describe "Execution blocks" do
  describe "threads" do
    it "creates thread execution context" do
      class ThreadPipeline
        include Minigun::DSL

        pipeline do
          threads(20) do
            processor :work do |item|
              emit(item)
            end
          end
        end
      end

      # Verify context is set correctly
    end
  end

  describe "processes" do
    it "creates process execution context" do
      # Similar test
    end
  end

  describe "process_per_batch" do
    it "creates per-batch execution context" do
      # Test
    end
  end

  describe "nested contexts" do
    it "does not allow nesting" do
      expect {
        class NestedPipeline
          include Minigun::DSL

          pipeline do
            threads(10) do
              processes(4) do
                # Should raise error
              end
            end
          end
        end
      }.to raise_error(/Cannot nest execution contexts/)
    end
  end
end
```

#### Step 1.2: Modify Stage Addition to Track Context
**File**: `lib/minigun/dsl.rb`

```ruby
def producer(name = :producer, options = {}, &block)
  # Inherit execution context from surrounding block
  options[:execution_context] = current_execution_context

  self.class._minigun_task.add_stage(:producer, name, options, &block)
end

def processor(name, options = {}, &block)
  options[:execution_context] = current_execution_context

  self.class._minigun_task.add_stage(:processor, name, options, &block)
end

def consumer(name = :consumer, options = {}, &block)
  options[:execution_context] = current_execution_context

  self.class._minigun_task.add_stage(:consumer, name, options, &block)
end
```

#### Step 1.3: Create Execution::Executor
**File**: `lib/minigun/execution/executor.rb`

```ruby
module Minigun
  module Execution
    class Executor
      def initialize(pipeline)
        @pipeline = pipeline
        @context_pools = {}
        @active_contexts = []
      end

      def execute
        # Group stages by execution context
        context_groups = group_stages_by_context

        # Create pools for each context type
        create_context_pools(context_groups)

        # Execute each group
        context_groups.each do |context_config, stages|
          execute_group(context_config, stages)
        end

        # Wait for completion
        wait_all
      ensure
        cleanup_all
      end

      private

      def group_stages_by_context
        # Group stages that share execution context
        groups = Hash.new { |h, k| h[k] = [] }

        @pipeline.stages.each do |name, stage|
          context = stage.options[:execution_context]
          groups[context] << stage
        end

        groups
      end

      def create_context_pools(groups)
        groups.each_key do |context_config|
          type = context_config[:type]
          size = context_config[:pool_size]

          next if @context_pools[type]

          @context_pools[type] = ContextPool.new(
            type: type,
            max_size: size
          )
        end
      end

      def execute_group(context_config, stages)
        if context_config[:mode] == :per_batch
          execute_per_batch(context_config, stages)
        else
          execute_pooled(context_config, stages)
        end
      end

      def execute_pooled(context_config, stages)
        type = context_config[:type]
        pool = @context_pools[type]

        stages.each do |stage|
          context = pool.acquire("stage:#{stage.name}")

          context.execute do
            stage.execute(@pipeline.context)
          end

          @active_contexts << context
        end
      end

      def execute_per_batch(context_config, stages)
        # Implement per-batch spawning logic
        # Similar to current spawn_fork behavior
      end

      def wait_all
        @active_contexts.each(&:join)
      end

      def cleanup_all
        @context_pools.values.each(&:terminate_all)
      end
    end
  end
end
```

**Tests**: `spec/unit/execution/executor_spec.rb`

---

### Phase 2: Integrate Executor into Pipeline

**Duration**: 3-4 days

#### Step 2.1: Update Pipeline to Use Executor
**File**: `lib/minigun/pipeline.rb`

```ruby
class Pipeline
  def run_with_executor(context)
    @context = context

    # Use new Executor if stages have execution_context
    if uses_execution_blocks?
      executor = Execution::Executor.new(self)
      executor.execute
    else
      # Fall back to legacy execution
      run_normal_pipeline(context)
    end

    @stats
  end

  private

  def uses_execution_blocks?
    @stages.values.any? { |s| s.options[:execution_context] }
  end

  # Keep old method for backward compatibility
  alias run_legacy run_normal_pipeline
  alias run_normal_pipeline run_with_executor
end
```

#### Step 2.2: Map Old Strategies to New Contexts
**File**: `lib/minigun/pipeline.rb`

```ruby
def map_strategy_to_execution_context(strategy)
  case strategy
  when :threaded, nil
    { type: :thread, pool_size: @config[:max_threads] || 5 }
  when :spawn_thread
    { type: :thread, mode: :per_batch, max: @config[:max_threads] || 10 }
  when :spawn_fork
    { type: :process, mode: :per_batch, max: @config[:max_processes] || 4 }
  when :fork_ipc
    { type: :process, pool_size: @config[:max_processes] || 4 }
  when :ractor, :spawn_ractor
    { type: :ractor, pool_size: @config[:max_ractors] || 4 }
  else
    { type: :thread, pool_size: 5 }
  end
end
```

**Tests**: `spec/unit/pipeline/executor_integration_spec.rb`

---

### Phase 3: Deprecate Old API

**Duration**: 2-3 days

#### Step 3.1: Add Deprecation Warnings
**File**: `lib/minigun/dsl.rb`

```ruby
module ClassMethods
  def max_threads(value)
    warn "[DEPRECATED] max_threads is deprecated. Use 'threads(#{value})' block instead."
    _minigun_task.set_config(:max_threads, value)
  end

  def max_processes(value)
    warn "[DEPRECATED] max_processes is deprecated. Use 'processes(#{value})' block instead."
    _minigun_task.set_config(:max_processes, value)
  end

  def spawn_fork(name, options = {}, &block)
    warn "[DEPRECATED] spawn_fork is deprecated. Use 'process_per_batch' instead:\n" \
         "  batch N\n" \
         "  process_per_batch(max: M) do\n" \
         "    consumer :#{name} do |batch|\n" \
         "      # ...\n" \
         "    end\n" \
         "  end"

    processor(name, options.merge(strategy: :spawn_fork), &block)
  end

  # Similar for spawn_thread, spawn_ractor
end
```

#### Step 3.2: Update All Examples
**Files**: `examples/*.rb`

**Migration script**: `scripts/migrate_to_execution_blocks.rb`
```ruby
#!/usr/bin/env ruby
# Automatically migrate to execution blocks

def migrate_file(file)
  content = File.read(file)

  # Replace max_threads N with threads(N) do wrapper
  # Replace spawn_fork with process_per_batch
  # Replace strategy: :threaded (remove - it's default)
  # etc.

  File.write(file, new_content)
end

Dir.glob('examples/*.rb').each { |f| migrate_file(f) }
```

#### Step 3.3: Update All Tests
**Files**: `spec/**/*_spec.rb`

Manually update integration tests to use new syntax.

---

### Phase 4: Remove Old API

**Duration**: 2-3 days

#### Step 4.1: Remove Deprecated Methods
**File**: `lib/minigun/dsl.rb`

Delete:
- `spawn_fork`
- `spawn_thread`
- `spawn_ractor`
- `max_threads` (or keep as alias to `threads`)
- `max_processes` (or keep as alias to `processes`)
- `strategy:` option support

#### Step 4.2: Remove Old Execution Code
**File**: `lib/minigun/pipeline.rb`

Delete:
- `consume_in_threads`
- `fork_consumer_process`
- `consume_in_ractors`
- All the old spawn logic

Keep only new Executor-based execution.

#### Step 4.3: Delete ExecutionStrategy Module
**File**: `lib/minigun/execution_strategy.rb`

**Delete entire file** - no longer needed!

Contexts replace strategies completely.

---

### Phase 5: Optimize and Polish

**Duration**: 1 week

#### Step 5.1: Implement Affinity Optimization
**File**: `lib/minigun/execution/executor.rb`

```ruby
def optimize_execution_plan
  # Use ExecutionPlan for affinity analysis
  plan = ExecutionPlan.new(@pipeline.dag, @pipeline.stages, @pipeline.config)
  plan.plan!

  # Colocate stages when beneficial
  @colocated_groups = plan.colocated_stages
  @independent_stages = plan.independent_stages
end
```

#### Step 5.2: Add Smart Defaults
```ruby
def default_pool_size(type)
  case type
  when :thread
    ENV.fetch('MINIGUN_THREADS', 5).to_i
  when :process
    ENV.fetch('MINIGUN_PROCESSES', 2).to_i
  when :ractor
    ENV.fetch('MINIGUN_RACTORS', 4).to_i
  end
end
```

#### Step 5.3: Performance Testing
```bash
# Benchmark old vs new
bundle exec ruby benchmarks/execution_comparison.rb
```

Ensure new system is as fast or faster.

---

## Testing Strategy

### Unit Tests

**New test files**:
- `spec/unit/dsl/execution_blocks_spec.rb` - Block syntax
- `spec/unit/dsl/batch_spec.rb` - Batching
- `spec/unit/execution/executor_spec.rb` - Executor logic
- `spec/unit/execution/per_batch_spec.rb` - Per-batch execution

**Updated tests**:
- All `spec/minigun/*_spec.rb` - Update to new syntax
- All `spec/unit/*_spec.rb` - Update to new syntax

### Integration Tests

**Update all**:
- `spec/integration/examples_spec.rb` - All examples work
- `spec/integration/errors_spec.rb` - Error handling
- `spec/integration/from_keyword_spec.rb` - Routing still works
- etc.

### Performance Tests

**New file**: `benchmarks/execution_blocks_benchmark.rb`
```ruby
require 'benchmark/ips'

Benchmark.ips do |x|
  x.report("threads block") do
    # Run pipeline with threads block
  end

  x.report("old threaded strategy") do
    # Run with old strategy
  end

  x.compare!
end
```

---

## Migration Guide for Users

**File**: `MIGRATION_GUIDE_EXECUTION.md`

```markdown
# Migration Guide: Execution Block Syntax

## What Changed

Strategy-based execution replaced with execution blocks.

## Before/After Examples

### Replace max_threads/max_processes

```ruby
# Before
class MyPipeline
  include Minigun::DSL

  max_threads 50
  max_processes 4

  producer :gen do
    emit(data)
  end
end

# After
class MyPipeline
  include Minigun::DSL

  pipeline do
    producer :gen do
      emit(data)
    end

    threads(50) do
      # stages that use threads
    end
  end
end
```

### Replace spawn_fork

```ruby
# Before
spawn_fork :heavy do |item|
  process(item)
end

# After
batch 1000

process_per_batch(max: 4) do
  consumer :heavy do |batch|
    batch.each { |item| process(item) }
  end
end
```

### Remove strategy: options

```ruby
# Before
processor :work, strategy: :threaded do |item|
  emit(item)
end

# After
processor :work do |item|
  emit(item)
end
# Default is threads - no need to specify
```

## Cheat Sheet

| Old | New |
|-----|-----|
| `max_threads 50` | `threads(50) do ... end` |
| `max_processes 4` | `processes(4) do ... end` |
| `spawn_fork` | `process_per_batch(max: N)` |
| `spawn_thread` | `thread_per_batch(max: N)` |
| `spawn_ractor` | `ractor_per_batch(max: N)` |
| `strategy: :threaded` | (default, remove) |
| `strategy: :fork_ipc` | `processes(N) do ... end` |
```

---

## Rollback Plan

If critical issues:

1. Keep old API alongside new (feature flag)
2. Fix issues in new implementation
3. Re-enable new API

---

## Success Criteria

- [ ] All 352+ tests pass with new syntax
- [ ] All 26+ examples migrated and working
- [ ] No `spawn_*` methods remain
- [ ] No `strategy:` options in codebase
- [ ] Performance equal or better
- [ ] No `ExecutionStrategy` module
- [ ] Executor fully integrated
- [ ] Documentation complete

---

## Timeline

- **Week 1**: Phase 1 - Add new DSL methods
- **Week 2**: Phase 2 - Integrate Executor
- **Week 3**: Phase 3 - Deprecate old API
- **Week 4**: Phase 4 - Remove old code
- **Week 5**: Phase 5 - Optimize and polish

**Total**: 5 weeks

---

## Dependencies

- Requires Refactor 1 (pipeline wrapper) to be complete
- Execution context infrastructure already exists
- ExecutionPlan already implemented

---

## Risk Assessment

**Medium Risk**:
- Core execution logic changes
- Many moving parts
- Performance sensitive

**Mitigation**:
- Keep old system working during migration
- Comprehensive testing
- Performance benchmarking
- Gradual rollout
- Can run both systems in parallel initially

---

## Key Files to Modify

1. `lib/minigun/dsl.rb` - Add execution block methods
2. `lib/minigun/execution/executor.rb` - New file, main logic
3. `lib/minigun/pipeline.rb` - Integrate executor
4. `lib/minigun/execution_strategy.rb` - DELETE
5. `examples/*.rb` - Update all 26 files
6. `spec/**/*_spec.rb` - Update all tests

---

## Commit Strategy

1. Commit: "Add execution block DSL methods"
2. Commit: "Implement Execution::Executor"
3. Commit: "Integrate Executor into Pipeline"
4. Commit: "Add deprecation warnings to old API"
5. Commit: "Migrate all examples to new syntax"
6. Commit: "Update all tests to new syntax"
7. Commit: "Remove deprecated methods"
8. Commit: "Delete ExecutionStrategy module"
9. Commit: "Optimize execution with affinity"
10. Commit: "Performance improvements and polish"

