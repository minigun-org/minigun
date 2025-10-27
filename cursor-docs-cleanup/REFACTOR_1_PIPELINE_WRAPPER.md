# Refactor 1: Pipeline Wrapper Requirement

## Goal
Make `pipeline do` wrapper required and support multiple pipeline blocks for better organization.

---

## Current State

```ruby
class MyPipeline
  include Minigun::DSL

  # Stages defined at class level (no wrapper)
  producer :gen do
    emit(data)
  end

  processor :work do |item|
    emit(item * 2)
  end

  consumer :save do |item|
    store(item)
  end
end
```

---

## Target State

```ruby
class MyPipeline
  include Minigun::DSL

  # Required wrapper at instance level
  pipeline do
    producer :gen do
      emit(data)
    end

    processor :work do |item|
      emit(item * 2)
    end

    consumer :save do |item|
      store(item)
    end
  end
end
```

---

## Benefits

1. **Instance Variables Work**: Can use `@variables` from `initialize`
2. **Multiple Definitions**: Can have multiple `pipeline do` blocks
3. **Conditional Logic**: Can define pipelines conditionally
4. **Clear Boundary**: Obvious where pipeline is defined
5. **Runtime Configuration**: Values evaluated at runtime, not class load time

---

## Step-by-Step Execution Plan

### Phase 1: Add Instance-Level Support (No Breaking Changes)

**Duration**: 2-3 days

#### Step 1.1: Add Instance Method `pipeline`
**File**: `lib/minigun/dsl.rb`

```ruby
module Minigun
  module DSL
    # Add instance method for pipeline definition
    def pipeline(&block)
      # Evaluate block in instance context
      @_pipeline_blocks ||= []
      @_pipeline_blocks << block

      # Store for execution
      self.class._minigun_task.add_instance_pipeline(self, &block)
    end

    # Instance methods for stage definition
    def producer(name = :producer, options = {}, &block)
      self.class._minigun_task.add_stage(:producer, name, options, &block)
    end

    def processor(name, options = {}, &block)
      self.class._minigun_task.add_stage(:processor, name, options, &block)
    end

    def consumer(name = :consumer, options = {}, &block)
      self.class._minigun_task.add_stage(:consumer, name, options, &block)
    end

    def accumulator(name = :accumulator, options = {}, &block)
      self.class._minigun_task.add_stage(:accumulator, name, options, &block)
    end

    def batch(size)
      self.class._minigun_task.add_accumulator(size)
    end
  end
end
```

**Tests**: `spec/unit/dsl/instance_pipeline_spec.rb`
```ruby
RSpec.describe "Instance-level pipeline" do
  it "allows pipeline definition in instance method" do
    class TestPipeline
      include Minigun::DSL

      pipeline do
        producer :gen do
          emit(1)
        end
      end
    end

    pipeline = TestPipeline.new
    expect(pipeline).to respond_to(:run)
  end

  it "allows access to instance variables" do
    class ConfigurablePipeline
      include Minigun::DSL

      def initialize(count:)
        @count = count
      end

      pipeline do
        producer :gen do
          @count.times { |i| emit(i) }
        end
      end
    end

    pipeline = ConfigurablePipeline.new(count: 5)
    # Test that it uses @count
  end
end
```

#### Step 1.2: Support Multiple `pipeline do` Blocks
**File**: `lib/minigun/dsl.rb`

```ruby
def pipeline(&block)
  @_pipeline_blocks ||= []
  @_pipeline_blocks << block

  # If this is the first call, evaluate it
  # If multiple calls, merge them
  if @_pipeline_blocks.size == 1
    instance_eval(&block)
  else
    # Merge with existing pipeline
    instance_eval(&block)
  end
end
```

**Tests**: `spec/unit/dsl/multiple_pipelines_spec.rb`
```ruby
RSpec.describe "Multiple pipeline blocks" do
  it "allows multiple pipeline do blocks" do
    class MultiBlockPipeline
      include Minigun::DSL

      pipeline do
        producer :gen do
          emit(1)
        end
      end

      pipeline do
        processor :work do |item|
          emit(item * 2)
        end
      end

      pipeline do
        consumer :save do |item|
          # save
        end
      end
    end

    pipeline = MultiBlockPipeline.new
    # Should have all 3 stages
  end
end
```

#### Step 1.3: Update Task to Handle Instance Pipelines
**File**: `lib/minigun/task.rb`

```ruby
class Task
  def add_instance_pipeline(instance, &block)
    # Create or get instance-specific pipeline
    @instance_pipelines ||= {}
    @instance_pipelines[instance] ||= @root_pipeline.dup

    # Evaluate block in instance context
    instance.instance_eval(&block)
  end

  def run(context)
    # Check if instance has custom pipeline
    if @instance_pipelines && @instance_pipelines[context]
      pipeline = @instance_pipelines[context]
    else
      pipeline = @root_pipeline
    end

    # Run the pipeline
    runner = Runner.new(pipeline, context, @config)
    runner.run
  end
end
```

---

### Phase 2: Deprecate Class-Level Definitions

**Duration**: 1 day

#### Step 2.1: Add Deprecation Warnings
**File**: `lib/minigun/dsl.rb`

```ruby
module ClassMethods
  def producer(name = :producer, options = {}, &block)
    warn "[DEPRECATED] Class-level stage definitions are deprecated. " \
         "Use 'pipeline do' wrapper instead.\n" \
         "  Example:\n" \
         "    pipeline do\n" \
         "      producer :#{name} do\n" \
         "        # ...\n" \
         "      end\n" \
         "    end"

    _minigun_task.add_stage(:producer, name, options, &block)
  end

  # Same for processor, consumer, accumulator
end
```

#### Step 2.2: Update All Examples
**Files**: `examples/*.rb` (26 files)

**Script**: `scripts/migrate_to_pipeline_wrapper.rb`
```ruby
#!/usr/bin/env ruby
# Script to automatically wrap examples in pipeline do

Dir.glob('examples/*.rb').each do |file|
  content = File.read(file)

  # Find class definition
  if content =~ /(class \w+\s+include Minigun::DSL.*?)(  producer|  processor|  consumer)/m
    # Insert pipeline do wrapper
    new_content = content.gsub(
      /(class \w+.*?include Minigun::DSL\n)(  )/m,
      "\\1\n  pipeline do\n\\2"
    )

    # Add closing end
    # ... (more logic)

    File.write(file, new_content)
  end
end
```

**Manual review** all examples after script runs.

#### Step 2.3: Update Documentation
**Files**:
- `README.md`
- `ARCHITECTURE.md`
- All `*.md` documentation files

---

### Phase 3: Make It Required

**Duration**: 1 day

#### Step 3.1: Remove Class-Level Stage Methods
**File**: `lib/minigun/dsl.rb`

```ruby
module ClassMethods
  # Remove these methods:
  # - producer
  # - processor
  # - consumer
  # - accumulator

  # Keep only configuration methods:
  def retries(value)
    _minigun_task.set_config(:max_retries, value)
  end
end
```

#### Step 3.2: Ensure All Tests Pass
```bash
bundle exec rspec
# Should be 0 failures after migration
```

#### Step 3.3: Update Error Messages
**File**: `lib/minigun/dsl.rb`

```ruby
module ClassMethods
  def method_missing(method, *args, &block)
    if [:producer, :processor, :consumer, :accumulator].include?(method)
      raise NoMethodError,
        "Stage definitions must be inside 'pipeline do' block.\n\n" \
        "Example:\n" \
        "  class MyPipeline\n" \
        "    include Minigun::DSL\n" \
        "\n" \
        "    pipeline do\n" \
        "      #{method} :my_stage do\n" \
        "        # ...\n" \
        "      end\n" \
        "    end\n" \
        "  end"
    else
      super
    end
  end
end
```

---

### Phase 4: Cleanup

**Duration**: 1 day

#### Step 4.1: Remove Old Code
- Delete old class-level stage definition methods
- Remove compatibility shims
- Clean up Task code

#### Step 4.2: Update Tests
- Remove tests for class-level definitions
- Ensure all instance-level tests pass

#### Step 4.3: Update Changelog
**File**: `CHANGELOG.md`

```markdown
## [NEXT_VERSION] - YYYY-MM-DD

### Breaking Changes

- **REQUIRED**: Stage definitions must now be inside `pipeline do` block
  - This enables instance variable access and runtime configuration
  - Migration: wrap your stage definitions in `pipeline do...end`

  ```ruby
  # Before
  class MyPipeline
    include Minigun::DSL
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
    end
  end
  ```

### New Features

- Multiple `pipeline do` blocks supported
- Instance variables accessible in pipeline definitions
- Runtime configuration of pipelines
```

---

## Testing Strategy

### Unit Tests
- `spec/unit/dsl/instance_pipeline_spec.rb` - Instance-level pipeline
- `spec/unit/dsl/multiple_pipelines_spec.rb` - Multiple blocks
- `spec/unit/dsl/instance_variables_spec.rb` - @variable access
- `spec/unit/dsl/pipeline_errors_spec.rb` - Error handling

### Integration Tests
- Update ALL existing integration tests to use `pipeline do`
- `spec/integration/examples_spec.rb` - All examples still work

### Manual Testing
```bash
# Test each example manually
ruby examples/00_quick_start.rb
ruby examples/01_sequential_default.rb
# ... etc
```

---

## Migration Guide for Users

**File**: `MIGRATION_GUIDE.md`

```markdown
# Migration Guide: Pipeline Wrapper Requirement

## What Changed

Stage definitions must now be inside `pipeline do` block.

## Why

- Access to instance variables (`@var`)
- Runtime configuration
- Multiple pipeline blocks
- Clearer structure

## How to Migrate

### Step 1: Add `pipeline do` wrapper

```ruby
# Before
class MyPipeline
  include Minigun::DSL

  producer :gen do
    emit(data)
  end

  consumer :save do |item|
    store(item)
  end
end

# After
class MyPipeline
  include Minigun::DSL

  pipeline do
    producer :gen do
      emit(data)
    end

    consumer :save do |item|
      store(item)
    end
  end
end
```

### Step 2: Move configuration to initialize (optional)

```ruby
class MyPipeline
  include Minigun::DSL

  def initialize(count: 100)
    @count = count
  end

  pipeline do
    producer :gen do
      @count.times { |i| emit(i) }
    end
  end
end
```

## Automated Migration

Run this script to migrate your code:

```bash
ruby scripts/migrate_to_pipeline_wrapper.rb
```

Then review changes and test!
```

---

## Rollback Plan

If critical issues found:

1. Keep both APIs temporarily
2. Make class-level optional (not required)
3. Fix issues
4. Re-attempt migration

---

## Success Criteria

- [ ] All 352+ tests pass
- [ ] All 26+ examples updated and working
- [ ] No class-level stage definitions remain
- [ ] Documentation updated
- [ ] Migration guide written
- [ ] No deprecation warnings in test suite
- [ ] Performance unchanged

---

## Timeline

- **Week 1**: Phase 1 - Add instance-level support
- **Week 2**: Phase 2 - Deprecate class-level
- **Week 3**: Phase 3 - Make required, update all code
- **Week 4**: Phase 4 - Cleanup and documentation

**Total**: 4 weeks

---

## Risk Assessment

**Low Risk**:
- Changes are isolated to DSL
- Can be incremental
- Tests catch issues

**Mitigation**:
- Comprehensive test coverage
- Gradual rollout (support both initially)
- Clear migration guide
- Automated migration script

