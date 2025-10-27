# Queue-Based DSL Refactor Plan

## Goal
Replace the `emit()`-based DSL with a clean queue-based DSL that passes queue arguments to blocks.

## Current DSL (emit-based)
```ruby
producer :generate do
  5.times { |i| emit(i + 1) }
end

processor :double do |num|
  emit(num * 2)
end

consumer :collect do |num|
  @results << num
end

# Explicit routing
processor :route do |item|
  emit_to_stage(:specific_stage, item)
end
```

## New DSL (queue-based)
```ruby
producer :generate do |output|
  5.times { |i| output << (i + 1) }
end

processor :double do |num, output|
  output << (num * 2)
end

consumer :collect do |num|
  @results << num  # No output queue for terminal stages
end

# Explicit routing with "magic sauce"
processor :route do |item, output|
  output.to(:specific_stage) << item
end

# Advanced: Stage with input loop
stage :forwarder do |input, output|
  while (item = input.pop) != AllUpstreamsDone.instance(:forwarder)
    output << (item * 2)
  end
end
```

## Architecture Changes

### 1. Queue Wrappers (✓ CREATED)
**File:** `lib/minigun/queue_wrappers.rb`

- `AllUpstreamsDone` - Sentinel object per stage
- `InputQueue` - Wraps input queue, handles END messages, returns sentinel when all upstreams done
- `OutputQueue` - Wraps output, routes to downstream, has `.to(stage)` for explicit routing

### 2. Stage Execution Changes
**File:** `lib/minigun/stage.rb`

**REMOVE:**
- All `emit` and `emit_to_stage` singleton method definition logic
- `execute_with_emit` method complexity
- Thread-local emissions storage
- Context wrapping/delegation

**UPDATE:**
- `execute()` method to accept `input_queue:` and `output_queue:` keyword args
- Use block arity to determine arguments:
  - `arity 0` or `-1`: Old DSL, no args (backwards compat)
  - `arity 1` + `producer?`: Pass `output` queue
  - `arity 1` + `!producer?`: Pass `item` only (consumer)
  - `arity 2` + has `input_queue`: Pass `input, output` (stage with loop)
  - `arity 2` + no `input_queue`: Pass `item, output` (processor)

### 3. StageWorker Changes
**File:** `lib/minigun/execution/stage_worker.rb`

**Current flow:**
```ruby
results = execute_item(@stage, item)
route_results(results, dag, runtime_edges, stage_input_queues)
```

**New flow:**
```ruby
# Create wrapped queues
input_queue = InputQueue.new(raw_queue, stage_name, upstream_sources)
output_queue = OutputQueue.new(stage_name, downstream_queues, all_queues, runtime_edges)

# Execute with queues
@stage.execute(context, item: item, input_queue: input_queue, output_queue: output_queue)

# No need to route results - queues handle it!
```

**Key changes:**
- Create `InputQueue` wrapper with upstream tracking
- Create `OutputQueue` wrapper with downstream routing
- Remove `route_results` logic (handled by OutputQueue)
- Remove `execute_item` wrapper (executor calls execute directly)

### 4. Pipeline Producer Changes
**File:** `lib/minigun/pipeline.rb`

**Current:** Producers define `emit` on context that routes to downstream queues

**New:**
- Create `OutputQueue` wrapper for producer context
- Pass it as block argument if arity allows
- For old DSL (arity 0), still define `emit` method for backwards compat (SKIP THIS - no backwards compat!)

### 5. Executor Changes
**File:** `lib/minigun/execution/executor.rb`

**Update `run_stage_logic`:**
```ruby
def run_stage_logic(stage, item, user_context, input_queue: nil, output_queue: nil)
  stage.execute(user_context,
                item: item,
                input_queue: input_queue,
                output_queue: output_queue)
end
```

## Migration Strategy

### Phase 1: Infrastructure (DONE)
- [x] Create `queue_wrappers.rb`
- [x] Add require to `lib/minigun.rb`
- [x] Update `Stage#execute` signature

### Phase 2: Core Refactor (IN PROGRESS)
1. **StageWorker** - Create and pass queue wrappers
2. **Executor** - Update to pass queues through
3. **Pipeline** - Update producer context to use OutputQueue
4. **Stage** - Remove ALL emit logic, simplify execute_with_emit

### Phase 3: Testing
1. Test with `000_new_dsl_fixed.rb`
2. Fix any issues
3. Update all examples to new DSL (or delete old ones)

### Phase 4: Cleanup
1. Remove `delegate` require (no longer needed)
2. Remove old emit test specs
3. Update documentation

## Key Design Decisions

### Block Arity Detection
```ruby
case @block.arity
when 0, -1  # producer do ... end (old DSL)
when 1      # producer do |output| or consumer do |item|
when 2      # processor do |item, output| or stage do |input, output|
```

### END Signal Handling
- StageWorker still sends END Messages to queues
- InputQueue wrapper consumes them, tracks sources
- Returns `AllUpstreamsDone.instance(stage_name)` when all done
- User code checks: `while (item = input.pop) != AllUpstreamsDone.instance(:my_stage)`

### Explicit Routing
- `output << item` - routes to ALL downstream (DAG routing)
- `output.to(:stage) << item` - routes to specific stage
- `.to()` method tracks runtime edges for END signal handling
- Returns new OutputQueue scoped to that target

## Breaking Changes
- **REMOVE all emit() support** - No backwards compatibility
- **REMOVE emit_to_stage()** - Use `output.to(:stage)` instead
- All examples must be updated to new DSL

## Benefits
1. **No metaprogramming** - No singleton method manipulation
2. **Thread-safe by design** - Each execution gets its own queue wrappers
3. **Explicit data flow** - Queues make routing obvious
4. **Cleaner code** - No emissions tracking, no context wrapping
5. **Better debugging** - Can inspect queues, see what's routing where

## Risks
1. **Existing examples break** - Need to update all of them
2. **Learning curve** - Users need to understand queue-based model
3. **Arity complexity** - Block arity detection can be confusing

## Success Criteria
- [ ] `000_new_dsl_fixed.rb` runs successfully
- [ ] All queue wrapper tests pass
- [ ] No race conditions in parallel execution
- [ ] END signals properly terminate all stages
- [ ] Explicit routing with `.to()` works
- [ ] Performance is same or better than emit-based

