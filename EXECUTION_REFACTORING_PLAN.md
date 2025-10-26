# Execution System Refactoring Plan

## Goal: Best Possible User Experience

**Principle**: Zero configuration by default, powerful when needed

**Timeline**: Breaking changes OK - we're going for the ideal state

## Current Problems

1. **Confusing Strategy Names**: `spawn_fork`, `spawn_thread`, `:fork_ipc` - what do these mean?
2. **Scattered Config**: `max_threads`, `max_processes`, `max_retries` - inconsistent naming
3. **Manual Strategy Selection**: Users must know when to use each strategy
4. **Two Parallel Systems**: ExecutionStrategy and Execution::Context don't integrate
5. **Complex Internal Code**: `consume_in_threads`, `fork_consumer_process`, etc.

## Proposed New API

### Level 1: Simple (95% of use cases)

```ruby
class MyPipeline
  include Minigun::DSL
  
  producer :generate do
    emit(data)
  end
  
  processor :transform do |item|
    emit(item * 2)
  end
  
  consumer :save do |item|
    store(item)
  end
end

# System automatically:
# - Creates ExecutionPlan from DAG
# - Analyzes affinity (colocate sequential stages)
# - Allocates thread pool (default size: 5)
# - Uses contexts for all execution
# - Cleans up on completion
```

### Level 2: Configured (4% of use cases)

```ruby
class ConfiguredPipeline
  include Minigun::DSL
  
  # New unified configuration
  concurrency threads: 10, processes: 4
  
  producer :fetch do
    urls.each { |url| emit(url) }
  end
  
  # I/O-bound: automatic thread pool
  processor :download do |url|
    emit(HTTP.get(url))
  end
  
  # CPU-bound: explicit process isolation
  processor :parse, concurrency: :process do |html|
    emit(parse(html))
  end
  
  consumer :save do |item|
    db.save(item)
  end
end
```

### Level 3: Expert (1% of use cases)

```ruby
class ExpertPipeline
  include Minigun::DSL
  
  concurrency(
    threads: 20,
    processes: 4,
    inline: false  # Disable affinity optimization
  )
  
  producer :stream do
    emit(data)
  end
  
  # Fine-grained control
  processor :work,
    context: :fork,           # Explicit context type
    affinity: :independent,   # Override affinity
    pool_size: 2              # Custom pool size
  do |item|
    emit(process(item))
  end
  
  # Ractor support
  processor :parallel, context: :ractor do |item|
    emit(item)
  end
end
```

## New DSL Methods

### Configuration

```ruby
# Replace: max_threads, max_processes, max_retries
concurrency(threads: 10, processes: 4, retries: 3)

# Or individual
concurrency threads: 10
concurrency processes: 4
```

### Stage Options

```ruby
# Current:
processor :work, strategy: :spawn_fork do |item|
  # confusing
end

# New:
processor :work, concurrency: :process do |item|
  # clear - uses process isolation
end

processor :work, concurrency: :thread do |item|
  # clear - uses thread pool
end

processor :work, context: :fork do |item|
  # expert - explicit context type
end
```

### Remove Confusing Methods

Delete these:
- `spawn_fork` → use `concurrency: :process`
- `spawn_thread` → use `concurrency: :thread`  
- `spawn_ractor` → use `context: :ractor`

## Implementation Strategy

### Phase 1: Add New API (Parallel)

1. Add `concurrency` DSL method
2. Add `context:` and `affinity:` stage options
3. Map to existing execution (no behavior change yet)

### Phase 2: Integrate Execution Contexts

1. Create `Execution::Executor` to replace strategy system
2. Use ExecutionPlan in Pipeline execution
3. Replace internal threading with contexts
4. Delete old strategy implementations

### Phase 3: Cleanup

1. Remove old DSL methods (`spawn_*`)
2. Remove old config methods (keep as deprecated aliases)
3. Delete `ExecutionStrategy` module
4. Update all examples

## Detailed Implementation

### New Execution::Executor

Replaces ExecutionStrategy - uses contexts internally:

```ruby
module Minigun
  module Execution
    class Executor
      def initialize(pipeline)
        @pipeline = pipeline
        @plan = nil
        @pools = {}
      end
      
      def execute
        # Create execution plan
        @plan = ExecutionPlan.new(
          @pipeline.dag,
          @pipeline.stages,
          @pipeline.config
        ).plan!
        
        # Create context pools
        @plan.context_types.each do |type|
          @pools[type] = ContextPool.new(
            type: type,
            max_size: pool_size_for(type)
          )
        end
        
        # Execute producers
        execute_producers
        
        # Execute pipeline
        execute_stages
        
        # Wait for completion
        @pools.values.each(&:join_all)
      ensure
        @pools.values.each(&:terminate_all)
      end
      
      private
      
      def execute_producers
        @pipeline.producers.each do |producer|
          context_type = @plan.context_for(producer.name)
          pool = @pools[context_type]
          
          ctx = pool.acquire("producer:#{producer.name}")
          ctx.execute do
            producer.execute(@pipeline.context)
          end
        end
      end
      
      def execute_stages
        # Group by affinity
        @plan.affinity_groups.each do |parent, stages|
          if parent
            execute_colocated(parent, stages)
          else
            execute_independent(stages)
          end
        end
      end
      
      def execute_colocated(parent, stages)
        # All stages run sequentially in parent's context
        # No queues - direct function calls
        context_type = @plan.context_for(parent)
        pool = @pools[context_type]
        
        ctx = pool.acquire("colocated:#{parent}")
        ctx.execute do
          # Execute stages in sequence within same context
          stages.each do |stage_name|
            stage = @pipeline.stages[stage_name]
            # Process items through stage
          end
        end
      end
      
      def execute_independent(stages)
        # Each stage gets its own context
        stages.each do |stage_name|
          stage = @pipeline.stages[stage_name]
          context_type = @plan.context_for(stage_name)
          pool = @pools[context_type]
          
          ctx = pool.acquire("stage:#{stage_name}")
          ctx.execute do
            stage.execute(@pipeline.context)
          end
        end
      end
      
      def pool_size_for(type)
        case type
        when :thread
          @pipeline.config[:concurrency_threads] || 5
        when :fork
          @pipeline.config[:concurrency_processes] || 2
        when :ractor
          @pipeline.config[:concurrency_ractors] || 4
        else
          1
        end
      end
    end
  end
end
```

### Updated DSL

```ruby
module Minigun
  module DSL
    module ClassMethods
      # New unified configuration
      def concurrency(options = {})
        if options.is_a?(Hash)
          options.each do |key, value|
            case key
            when :threads
              _minigun_task.set_config(:concurrency_threads, value)
            when :processes
              _minigun_task.set_config(:concurrency_processes, value)
            when :ractors
              _minigun_task.set_config(:concurrency_ractors, value)
            when :retries
              _minigun_task.set_config(:max_retries, value)
            when :inline
              _minigun_task.set_config(:force_inline, value)
            end
          end
        else
          # Single value sets default type
          _minigun_task.set_config(:default_concurrency, options)
        end
      end
      
      # Deprecated aliases (backward compat during migration)
      def max_threads(value)
        warn "[DEPRECATED] Use 'concurrency threads: #{value}' instead"
        concurrency threads: value
      end
      
      def max_processes(value)
        warn "[DEPRECATED] Use 'concurrency processes: #{value}' instead"
        concurrency processes: value
      end
      
      # Stage methods now support new options
      def processor(name, options = {}, &block)
        # Map old :strategy to new :concurrency
        if options[:strategy]
          options[:concurrency] = map_strategy_to_concurrency(options[:strategy])
          options.delete(:strategy)
        end
        
        _minigun_task.add_stage(:processor, name, options, &block)
      end
      
      private
      
      def map_strategy_to_concurrency(strategy)
        case strategy
        when :spawn_fork then :process
        when :spawn_thread then :thread
        when :spawn_ractor then :ractor
        when :fork_ipc then :process
        when :threaded then :thread
        else strategy
        end
      end
    end
  end
end
```

### Updated Pipeline Execution

```ruby
class Pipeline
  def run_with_executor(context)
    @context = context
    
    # Use new Executor
    executor = Execution::Executor.new(self)
    executor.execute
    
    # Return stats
    @stats
  end
  
  # Old method kept for comparison during migration
  alias run_legacy run_normal_pipeline
  
  # Switch to new by default
  alias run_normal_pipeline run_with_executor
end
```

## Migration Path for Examples

### Before (Current)

```ruby
class Example
  include Minigun::DSL
  
  max_threads 10
  max_processes 4
  
  producer :gen do
    emit(1)
  end
  
  spawn_fork :heavy do |item|
    emit(process(item))
  end
  
  consumer :save do |item|
    store(item)
  end
end
```

### After (New)

```ruby
class Example
  include Minigun::DSL
  
  concurrency threads: 10, processes: 4
  
  producer :gen do
    emit(1)
  end
  
  processor :heavy, concurrency: :process do |item|
    emit(process(item))
  end
  
  consumer :save do |item|
    store(item)
  end
end
```

## Benefits

### For Users

1. **Clearer Intent**: `concurrency: :process` vs `spawn_fork`
2. **Less Configuration**: System handles affinity automatically
3. **Better Defaults**: Thread pool by default, process when needed
4. **Consistent API**: One way to configure concurrency
5. **Easier Learning**: Simple cases just work

### For Implementation

1. **Single System**: Only Execution::Context, not two systems
2. **Better Testing**: Use InlineContext for deterministic tests
3. **Easier Optimization**: ExecutionPlan can optimize automatically
4. **Cleaner Code**: Delete all the spawn/fork/thread methods
5. **Future-Proof**: Easy to add new context types

## Testing Strategy

1. **Keep Old Tests**: Run against both old and new during migration
2. **Add Context Tests**: All execution goes through contexts
3. **Benchmark**: Ensure new system is as fast or faster
4. **Compatibility**: Provide migration guide

## Timeline

1. **Week 1**: Implement `Execution::Executor` and new DSL
2. **Week 2**: Migrate Pipeline to use Executor
3. **Week 3**: Update all examples and tests
4. **Week 4**: Delete old code and document

## Open Questions

1. **Should we keep strategy option?** Or fully replace with concurrency?
2. **Default concurrency level?** Thread pool by default? Or inline with opt-in parallelism?
3. **Accumulator behavior?** Auto-batch before fork? Or explicit?
4. **Error handling?** How do context errors propagate?
5. **Nested pipelines?** How do they get contexts?

## Success Criteria

- [ ] All 352 tests pass with new system
- [ ] All 30 examples updated and working
- [ ] No `spawn_*` methods in DSL
- [ ] All execution uses Execution::Context
- [ ] Documentation updated
- [ ] Performance equal or better

---

**Next Step**: Implement `Execution::Executor` and integrate with Pipeline

