# Concurrency Architecture Proposal

## Problem Statement

### Current Issues
1. **Scattered Threading Logic**: Thread spawn/join code duplicated across `start_producer`, `start_accumulator`, `consume_in_threads`, etc.
2. **No Unified Abstraction**: Each concurrency model (thread/fork/ractor) implemented separately
3. **Unclear Execution Affinity**: No model for determining WHERE a stage executes relative to its sources
4. **Communication Coupling**: Queue types tightly coupled to execution model

### Key Questions
1. Where does a consumer execute? Same thread as producer? New thread? New process?
2. If multiple sources feed a stage, which source's context does it run in?
3. How do we abstract thread/fork/ractor behind a common interface?
4. How do we handle communication (queues) transparently?

## Proposed Solution

### 1. Execution Context Abstraction

```ruby
module Minigun
  module Execution
    # Base class for execution contexts
    class Context
      attr_reader :name

      def initialize(name)
        @name = name
      end

      # Execute code in this context (non-blocking)
      def execute(&block)
        raise NotImplementedError
      end

      # Wait for this context to complete
      def join
        raise NotImplementedError
      end

      # Check if context is alive
      def alive?
        raise NotImplementedError
      end

      # Terminate this context
      def terminate
        raise NotImplementedError
      end
    end

    # Inline execution (same thread, no concurrency)
    class InlineContext < Context
      def execute(&block)
        @result = block.call
        self
      end

      def join
        @result
      end

      def alive?
        false # Already completed
      end

      def terminate
        # No-op
      end
    end

    # Thread-based execution
    class ThreadContext < Context
      def execute(&block)
        @thread = Thread.new(&block)
        self
      end

      def join
        @thread.join
      end

      def alive?
        @thread&.alive? || false
      end

      def terminate
        @thread&.kill
      end
    end

    # Fork-based execution (process)
    class ForkContext < Context
      def execute(&block)
        @pid = fork(&block)
        self
      end

      def join
        return unless @pid
        Process.wait(@pid)
        @pid = nil
      end

      def alive?
        return false unless @pid
        Process.waitpid(@pid, Process::WNOHANG).nil?
      rescue Errno::ECHILD
        false
      end

      def terminate
        return unless @pid
        Process.kill('TERM', @pid)
        join
      rescue Errno::ESRCH
        # Already dead
      end
    end

    # Ractor-based execution
    class RactorContext < Context
      def execute(&block)
        @ractor = Ractor.new(&block)
        self
      end

      def join
        @ractor.take
      end

      def alive?
        # Ractors don't have a direct alive? check
        # Could track state manually
        true
      end

      def terminate
        # Ractors can't be killed directly
        # Would need to send shutdown message
      end
    end
  end
end
```

### 2. Context Pool

Manage a pool of execution contexts:

```ruby
module Minigun
  module Execution
    class ContextPool
      def initialize(type:, max_size:)
        @type = type  # :inline, :thread, :fork, :ractor
        @max_size = max_size
        @contexts = []
        @available = []
        @mutex = Mutex.new
      end

      # Get an available context or create one
      def acquire(name)
        @mutex.synchronize do
          context = @available.pop || create_context(name)
          @contexts << context
          context
        end
      end

      # Return context to pool (for reuse)
      def release(context)
        @mutex.synchronize do
          @available << context if @available.size < @max_size
        end
      end

      # Wait for all contexts to complete
      def join_all
        @contexts.each(&:join)
        @contexts.clear
      end

      # Terminate all contexts
      def terminate_all
        @contexts.each(&:terminate)
        @contexts.clear
      end

      private

      def create_context(name)
        case @type
        when :inline
          Execution::InlineContext.new(name)
        when :thread
          Execution::ThreadContext.new(name)
        when :fork
          Execution::ForkContext.new(name)
        when :ractor
          Execution::RactorContext.new(name)
        else
          raise ArgumentError, "Unknown context type: #{@type}"
        end
      end
    end
  end
end
```

### 3. Execution Affinity Model

Define WHERE each stage executes:

```ruby
module Minigun
  class ExecutionPlan
    attr_reader :dag, :stages, :config

    def initialize(dag, stages, config)
      @dag = dag
      @stages = stages
      @config = config
      @stage_contexts = {}  # stage_name => context_type
      @stage_affinity = {}  # stage_name => parent_stage_name (or nil)
    end

    # Analyze DAG and assign execution contexts
    def plan!
      # 1. Identify producers (no upstream) - always get their own context
      producers.each do |stage|
        assign_context(stage, context_type_for(stage), affinity: nil)
      end

      # 2. Topologically sort and assign contexts
      @dag.topological_sort.each do |stage_name|
        next if @stage_contexts.key?(stage_name)

        stage = @stages[stage_name]
        upstream = @dag.upstream(stage_name)

        # Determine affinity
        affinity = determine_affinity(stage, upstream)

        # Determine context type
        context_type = if affinity
          # Execute in same context as affinity parent
          @stage_contexts[affinity]
        else
          # Execute in own context
          context_type_for(stage)
        end

        assign_context(stage, context_type, affinity: affinity)
      end

      self
    end

    # Get context type for a stage
    def context_for(stage_name)
      @stage_contexts[stage_name]
    end

    # Get affinity parent for a stage (or nil if independent)
    def affinity_for(stage_name)
      @stage_affinity[stage_name]
    end

    # Should this stage run in same context as its source?
    def colocated?(stage_name, source_name)
      @stage_affinity[stage_name] == source_name
    end

    private

    def assign_context(stage, context_type, affinity:)
      @stage_contexts[stage.name] = context_type
      @stage_affinity[stage.name] = affinity
    end

    def context_type_for(stage)
      # Check stage's strategy
      case stage.strategy
      when :threaded
        :thread
      when :fork_ipc
        :fork
      when :ractor
        :ractor
      when :spawn_thread
        :thread  # But after accumulator
      when :spawn_fork
        :fork
      when :spawn_ractor
        :ractor
      else
        # Default based on config
        @config[:default_context] || :thread
      end
    end

    def determine_affinity(stage, upstream_stages)
      # Rules for affinity:
      # 1. If single upstream and it's a producer -> colocate
      # 2. If multiple upstream -> independent (needs own context)
      # 3. If upstream is accumulator -> always independent
      # 4. If stage requests specific strategy -> independent

      return nil if upstream_stages.size != 1

      upstream_name = upstream_stages.first
      upstream_stage = @stages[upstream_name]

      # Don't colocate with accumulators
      return nil if upstream_stage&.accumulator?

      # Don't colocate if stage has explicit strategy
      return nil if stage.strategy != :threaded

      # Colocate with upstream
      upstream_name
    end

    def producers
      @stages.values.select { |s| @dag.upstream(s.name).empty? }
    end
  end
end
```

### 4. Execution Orchestrator

Manages execution using the plan:

```ruby
module Minigun
  class ExecutionOrchestrator
    def initialize(pipeline)
      @pipeline = pipeline
      @pools = {}
      @contexts = {}
    end

    def execute(context)
      # Create execution plan
      plan = ExecutionPlan.new(
        @pipeline.dag,
        @pipeline.stages,
        @pipeline.config
      ).plan!

      # Create context pools
      plan.context_types.each do |type|
        @pools[type] = Execution::ContextPool.new(
          type: type,
          max_size: max_size_for(type)
        )
      end

      # Execute stages according to plan
      execute_plan(plan, context)

      # Wait for completion
      @pools.values.each(&:join_all)
    ensure
      # Cleanup
      @pools.values.each(&:terminate_all)
    end

    private

    def execute_plan(plan, context)
      # Group stages by affinity
      affinity_groups = group_by_affinity(plan)

      # Execute each group
      affinity_groups.each do |parent, stages|
        if parent
          # Colocated execution - run in parent's context
          execute_colocated(stages, plan, context)
        else
          # Independent execution - run in separate contexts
          execute_independent(stages, plan, context)
        end
      end
    end

    def execute_colocated(stages, plan, context)
      # All stages run in same context
      # Sequential execution within context
      # Communication via in-memory variables
    end

    def execute_independent(stages, plan, context)
      # Each stage gets its own context
      # Parallel execution
      # Communication via queues
      stages.each do |stage|
        context_type = plan.context_for(stage.name)
        pool = @pools[context_type]

        exec_context = pool.acquire("#{@pipeline.name}:#{stage.name}")
        @contexts[stage.name] = exec_context

        exec_context.execute do
          execute_stage(stage, context)
        end
      end
    end

    def max_size_for(type)
      case type
      when :thread
        @pipeline.config[:max_threads]
      when :fork
        @pipeline.config[:max_processes]
      when :ractor
        @pipeline.config[:max_ractors] || 4
      else
        1
      end
    end
  end
end
```

## Benefits

### 1. **Unified Abstraction**
- All concurrency models behind `ExecutionContext` interface
- Easy to add new models (e.g., fiber, async/await)
- Consistent API for spawn/join/terminate

### 2. **Explicit Affinity**
- Clear model for where stages execute
- Optimizes for data locality when beneficial
- Reduces communication overhead for colocated stages

### 3. **Flexible Strategy**
- Stage-level strategy override
- Pipeline-level default
- Automatic optimization based on DAG structure

### 4. **Better Resource Management**
- Context pools prevent resource exhaustion
- Reuse contexts when possible
- Clean shutdown and termination

### 5. **Testability**
- Easy to test with `InlineContext` (no concurrency)
- Mock contexts for unit tests
- Inject different strategies for testing

## Migration Path

### Phase 1: Introduce Abstractions (No Breaking Changes)
1. Add `Execution::Context` classes
2. Add `ContextPool`
3. Keep existing code working

### Phase 2: Add Execution Plan
1. Implement `ExecutionPlan`
2. Use in new code paths
3. Keep old paths as fallback

### Phase 3: Refactor to Use Orchestrator
1. Replace `start_producer` with orchestrator
2. Replace `start_accumulator` with orchestrator
3. Replace consumer spawning with orchestrator

### Phase 4: Remove Old Code
1. Delete old threading code
2. Remove duplicated logic
3. Clean up

## Examples

### Simple Sequential
```ruby
pipeline :process do
  producer :source do
    emit(1)
  end

  processor :double do |item|
    emit(item * 2)
  end

  consumer :sink do |item|
    puts item
  end
end

# Execution plan:
# source: ThreadContext (independent)
# double: colocated with source (same thread)
# sink: colocated with double (same thread)
```

### Parallel Processing
```ruby
pipeline :process do
  producer :source do
    1000.times { |i| emit(i) }
  end

  processor :expensive, strategy: :spawn_thread do |item|
    emit(expensive_computation(item))
  end

  consumer :sink do |item|
    puts item
  end
end

# Execution plan:
# source: ThreadContext (independent)
# expensive: ContextPool of ThreadContexts (max_threads)
# sink: ThreadContext (collects results)
```

### Fork for Isolation
```ruby
pipeline :process do
  producer :source do
    emit_sensitive_data
  end

  processor :untrusted, strategy: :fork_ipc do |item|
    # Runs in separate process for security
    emit(untrusted_transform(item))
  end

  consumer :sink do |item|
    store_securely(item)
  end
end

# Execution plan:
# source: ThreadContext
# untrusted: ForkContext (isolated process)
# sink: ThreadContext
# Communication via IPC queue
```

## Open Questions

1. **Ractor Communication**: Ractors have restrictions on shared objects. How do we handle context passing?

2. **Error Propagation**: How do errors in child contexts propagate to parent?

3. **Cancellation**: How do we cancel execution across contexts?

4. **Resource Limits**: How do we enforce global resource limits (e.g., max total threads)?

5. **Priority**: Should some stages have priority over others for context allocation?

6. **Dynamic Scaling**: Should context pools grow/shrink dynamically?

## Next Steps

1. Implement `Execution::Context` classes
2. Add unit tests for each context type
3. Implement `ContextPool`
4. Implement `ExecutionPlan` with basic affinity rules
5. Add integration tests
6. Implement `ExecutionOrchestrator`
7. Refactor one pipeline method to use orchestrator
8. Validate performance
9. Migrate remaining code
10. Remove old code

---

**This proposal provides a solid foundation for unified concurrency management and explicit execution affinity in Minigun.** 🚀

