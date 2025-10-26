# Complete Refactoring Roadmap

## Overview

Two major refactors to achieve the ideal DSL:

1. **Pipeline Wrapper Requirement** (4 weeks)
2. **Execution Block Syntax** (5 weeks)

**Total Timeline**: ~9 weeks (can be done sequentially or with some overlap)

---

## Before and After

### Current State
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

  consumer :save do |item|
    store(item)
  end
end

pipeline = MyPipeline.new
pipeline.run
```

### Target State
```ruby
class MyPipeline
  include Minigun::DSL

  def initialize(download_threads: 50, process_max: 4, batch_size: 1000)
    @download_threads = download_threads
    @process_max = process_max
    @batch_size = batch_size
  end

  pipeline do
    producer :gen do
      emit(data)
    end

    threads(@download_threads) do
      processor :work do |item|
        emit(item * 2)
      end
    end

    batch @batch_size

    process_per_batch(max: @process_max) do
      processor :heavy do |item|
        emit(process(item))
      end
    end

    consumer :save do |item|
      store(item)
    end
  end
end

pipeline = MyPipeline.new(download_threads: 100, process_max: 8)
pipeline.run
```

---

## Refactor 1: Pipeline Wrapper

**See**: `REFACTOR_1_PIPELINE_WRAPPER.md`

### Summary
- Make `pipeline do` wrapper required
- Enable instance-level definitions
- Support multiple `pipeline do` blocks
- Allow instance variable access

### Timeline: 4 Weeks
- Week 1: Add instance-level support
- Week 2: Deprecate class-level
- Week 3: Make required
- Week 4: Cleanup

### Key Changes
- Add `def pipeline(&block)` instance method
- Update all examples (26 files)
- Remove class-level stage methods
- Update documentation

### Breaking Changes
- ✅ Stage definitions must be inside `pipeline do`

---

## Refactor 2: Execution Blocks

**See**: `REFACTOR_2_EXECUTION_BLOCKS.md`

### Summary
- Replace strategies with execution blocks
- Add `threads(N) do`, `processes(N) do`, `ractors(N) do`
- Add `process_per_batch(max: N) do`
- Remove `spawn_*` methods and `strategy:` options
- Delete `ExecutionStrategy` module entirely

### Timeline: 5 Weeks
- Week 1: Add new DSL methods
- Week 2: Integrate Executor
- Week 3: Deprecate old API
- Week 4: Remove old code
- Week 5: Optimize

### Key Changes
- Add execution block methods
- Create `Execution::Executor`
- Update Pipeline to use Executor
- Delete old strategy code
- Update all examples and tests

### Breaking Changes
- ✅ `spawn_fork`, `spawn_thread`, `spawn_ractor` removed
- ✅ `strategy:` option removed
- ✅ `max_threads`, `max_processes` removed (or aliased)
- ✅ `ExecutionStrategy` module deleted

---

## Execution Sequence

### Option A: Sequential (Safer)

```
Weeks 1-4:  Refactor 1 (Pipeline Wrapper)
Weeks 5-9:  Refactor 2 (Execution Blocks)
```

**Pros:**
- ✅ Less risky - one thing at a time
- ✅ Easier to debug issues
- ✅ Clear checkpoints

**Cons:**
- ❌ Longer total time
- ❌ Two separate migration waves for users

### Option B: Overlapped (Faster)

```
Weeks 1-2:  Refactor 1 Phase 1 (Add instance support)
Weeks 3-4:  Refactor 1 Phase 2 & Start Refactor 2 Phase 1
Weeks 5-6:  Refactor 1 Phase 3 & Refactor 2 Phase 2
Weeks 7-9:  Complete both
```

**Pros:**
- ✅ Faster overall
- ✅ One migration wave for users

**Cons:**
- ❌ More complex
- ❌ Higher risk of conflicts
- ❌ Harder to track issues

### Recommendation: **Option A (Sequential)**

Less risk, clearer checkpoints, easier to debug.

---

## Migration Timeline for Users

### After Refactor 1 (Week 4)
Users need to:
```ruby
# Wrap stages in pipeline do
pipeline do
  producer :gen do
    # ...
  end
end
```

### After Refactor 2 (Week 9)
Users need to:
```ruby
# Replace spawn_* with execution blocks
# Before
spawn_fork :heavy do |item|
  # ...
end

# After
process_per_batch(max: 4) do
  processor :heavy do |item|
    # ...
  end
end
```

### Combined Migration (If doing sequentially)
Users can migrate both at once after week 9:
```ruby
# Before
class MyPipeline
  include Minigun::DSL

  max_threads 50
  spawn_fork :heavy do |item|
    # ...
  end
end

# After
class MyPipeline
  include Minigun::DSL

  pipeline do
    threads(50) do
      # stages
    end

    process_per_batch(max: 4) do
      processor :heavy do |item|
        # ...
      end
    end
  end
end
```

---

## Testing Strategy

### Refactor 1 Tests
- Instance pipeline definition
- Multiple pipeline blocks
- Instance variable access
- Error handling

### Refactor 2 Tests
- Execution block syntax
- Context pools
- Per-batch execution
- Executor integration

### Integration Tests
- All examples work
- All test suite passes
- Performance maintained

### Manual Testing Checklist
```bash
# After each phase
bundle exec rspec                    # All tests pass
ruby examples/00_quick_start.rb      # Examples work
bundle exec rspec --profile 10       # No perf regression
```

---

## Risk Management

### Refactor 1 Risks
**Low Risk**
- DSL changes only
- No execution logic changes
- Easy to rollback

### Refactor 2 Risks
**Medium Risk**
- Core execution changes
- Many moving parts
- Performance sensitive

### Mitigation
1. Keep both APIs during transition
2. Feature flag for new system
3. Comprehensive testing
4. Performance benchmarking
5. Gradual rollout

---

## Success Metrics

### After Refactor 1
- [ ] All 352+ tests pass
- [ ] All 26+ examples updated
- [ ] No class-level stage definitions
- [ ] Can use instance variables in pipeline

### After Refactor 2
- [ ] All tests pass with new syntax
- [ ] No `spawn_*` methods in codebase
- [ ] No `strategy:` options anywhere
- [ ] `ExecutionStrategy` module deleted
- [ ] Performance equal or better

### Overall
- [ ] Both refactors complete
- [ ] Documentation updated
- [ ] Migration guides written
- [ ] Zero regressions
- [ ] Users have clear migration path

---

## Files to Change

### Refactor 1 (Pipeline Wrapper)
```
lib/minigun/dsl.rb          - Add instance pipeline method
lib/minigun/task.rb         - Handle instance pipelines
examples/*.rb               - Update all examples (26 files)
spec/**/*_spec.rb           - Update all tests
README.md                   - Update examples
ARCHITECTURE.md             - Document new pattern
```

### Refactor 2 (Execution Blocks)
```
lib/minigun/dsl.rb                      - Add execution block methods
lib/minigun/execution/executor.rb       - NEW: Main executor
lib/minigun/pipeline.rb                 - Integrate executor
lib/minigun/execution_strategy.rb       - DELETE
examples/*.rb                           - Update syntax
spec/**/*_spec.rb                       - Update tests
```

---

## Dependencies

### Refactor 1 Dependencies
- None - can start immediately

### Refactor 2 Dependencies
- ✅ Execution context infrastructure (already exists)
- ✅ ExecutionPlan (already exists)
- ⚠️ Refactor 1 should be complete first (recommended)

---

## Rollback Plans

### Refactor 1 Rollback
If issues found:
1. Keep both APIs temporarily
2. Make wrapper optional
3. Fix issues
4. Re-attempt

### Refactor 2 Rollback
If issues found:
1. Feature flag to use old system
2. Fix executor issues
3. Re-enable new system

---

## Communication Plan

### Announcement (Before Starting)
```markdown
## Upcoming Breaking Changes

We're refactoring Minigun's DSL for better clarity and configurability.

**Timeline**: 9 weeks
**Your Action**: None yet - we'll provide migration guide

**What's changing**:
1. Stage definitions will require `pipeline do` wrapper
2. Execution syntax will change (`spawn_*` → execution blocks)

More details coming soon!
```

### During Refactor 1 (Week 2)
```markdown
## Migration Guide: Pipeline Wrapper

Stage definitions now need `pipeline do` wrapper.

See: MIGRATION_GUIDE.md

You have 2 weeks to migrate before it becomes required.
```

### During Refactor 2 (Week 7)
```markdown
## Migration Guide: Execution Blocks

Execution syntax has changed. See guide for details.

Old: `spawn_fork :heavy`
New: `process_per_batch(max: 4) do ... end`

See: MIGRATION_GUIDE_EXECUTION.md
```

### After Both Complete
```markdown
## Refactoring Complete! 🎉

Both refactors are done. Your pipeline DSL is now:
- ✅ More configurable
- ✅ Clearer intent
- ✅ Instance variable support
- ✅ Better defaults

Migration guides: [links]
```

---

## Next Steps

1. **Review plans** - Are we aligned on approach?
2. **Choose sequence** - Sequential or overlapped?
3. **Start Refactor 1** - Add instance pipeline support
4. **Create migration scripts** - Automate what we can
5. **Update documentation** - Keep docs in sync

---

## Questions to Decide

1. ✅ **Sequential or overlapped?** → Recommend sequential
2. ✅ **Keep old APIs temporarily?** → Yes, during deprecation
3. ✅ **Automated migration?** → Yes, where possible
4. ❓ **Feature flag for new system?** → Probably yes for Refactor 2
5. ❓ **Beta testing period?** → Depends on confidence level

---

**Ready to start?** Let's begin with Refactor 1, Phase 1!

