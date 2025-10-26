# Features to Implement from lib_old/spec_old

Based on analysis of the old codebase, here are valuable features and patterns that should be implemented:

## 1. Dynamic Queue Routing: `emit_to_queue(queue_name, item)`

**Status**: NOT IMPLEMENTED
**Priority**: HIGH
**Value**: Enables flexible, dynamic routing patterns

### Use Cases
- **Load Balancing**: Round-robin distribution to multiple processors
- **Priority Routing**: Route based on item properties (VIP users, urgent alerts)
- **Message Type Routing**: Route different message types to specialized processors
- **Multi-target Emission**: Send same item to multiple downstream stages

### Example Usage
```ruby
pipeline do
  processor :router do |request|
    # Route to specific server based on load
    server = case request[:id] % 3
             when 0 then :server_a
             when 1 then :server_b
             when 2 then :server_c
             end

    emit_to_queue(server, request)
  end

  processor :server_a, from: :router do |request|
    # Handle on server A
  end

  processor :server_b, from: :router do |request|
    # Handle on server B
  end

  processor :server_c, from: :router do |request|
    # Handle on server C
  end
end
```

### Implementation Notes
- Should allow multiple `emit_to_queue` calls in one stage
- Should validate that target queue exists
- Should work with regular `emit()` in same stage
- Needs to integrate with DAG routing

---

## 2. Context Variable: Access to Pipeline Instance

**Status**: PARTIALLY IMPLEMENTED
**Priority**: MEDIUM
**Value**: Allows stages to access instance variables and methods

### Current State
- Instance variables can be accessed in blocks via closure
- No explicit `context` variable exposed

### Desired Behavior
```ruby
class MyCrawler
  include Minigun::DSL

  def initialize
    @visited_urls = Set.new
    @stats = { pages: 0, errors: 0 }
  end

  pipeline do
    processor :fetch do |url|
      if context.visited_urls.include?(url)
        puts "Already visited: #{url}"
        return
      end

      context.visited_urls.add(url)
      context.stats[:pages] += 1

      emit(fetch_page(url))
    end
  end
end
```

### Implementation Notes
- `context` should refer to the pipeline instance
- Should work in all stage types
- May conflict with instance_exec context - needs careful design

---

## 3. Advanced IPC Fork Features

**Status**: BASIC IMPLEMENTATION EXISTS
**Priority**: LOW
**Value**: Better performance for large data transfers

### Features to Add
- **MessagePack Support**: Faster serialization than Marshal
- **Compression**: Zlib compression for large results (>1KB)
- **Chunked Transfer**: Split large data into chunks (>1MB)
- **Timeout Configuration**: Configurable pipe read timeout

### Implementation Notes
- Current `ForkContext` uses `IO.pipe` with `Marshal`
- Could add optional compression/MessagePack as opt-in features
- Would need to benchmark to prove value

---

## 4. Custom Accumulator Logic

**Status**: NOT IMPLEMENTED
**Priority**: HIGH
**Value**: Enables sophisticated batching patterns

### Current State
- `AccumulatorStage` batches by count only
- Single buffer for all items
- No type-based or property-based batching

### Desired Features
```ruby
# Batch by property
accumulator :email_batcher do |email|
  @batches ||= Hash.new { |h, k| h[k] = [] }

  # Batch by email type
  type = email[:type]
  @batches[type] << email

  # Emit when specific type reaches threshold
  if @batches[type].size >= batch_size_for(type)
    batch = @batches[type].dup
    @batches[type].clear

    # Route to different consumers based on type
    emit_to_queue(:"#{type}_sender", batch)
  end
end
```

### Implementation Notes
- Could provide `emit_to_queue` inside accumulator blocks
- Would need to handle flush logic for multiple internal buffers
- Accumulator should support custom logic, not just count-based

---

## 5. GC Management in Child Processes

**Status**: NOT IMPLEMENTED
**Priority**: MEDIUM
**Value**: Prevents memory bloat in long-running child processes

### Features
- Force GC before forking (minimize COW pages)
- Periodic GC in child processes processing large batches
- Configurable GC probability (e.g., 10% chance per sub-batch)

### Implementation
```ruby
# In ForkContext
def execute(task)
  # Force GC before forking to reduce memory footprint
  GC.start if should_gc_before_fork?

  pid = fork do
    # Process in batches with periodic GC
    items.each_slice(100) do |batch|
      process_batch(batch)

      # Periodic GC to prevent memory bloat
      GC.start if rand < @gc_probability
    end
  end
end
```

---

## 6. Advanced Routing Patterns (Examples to Add)

**Status**: NOT IMPLEMENTED
**Priority**: LOW
**Value**: Demonstrates powerful patterns to users

### Patterns to Document
1. **Load Balancer Pattern**: Round-robin to N workers
2. **Priority Queue Pattern**: Route by priority/VIP status
3. **Message Router Pattern**: Route by message type
4. **Web Crawler Pattern**: Recursive crawling with visited set
5. **ETL Pipeline Pattern**: Extract, Transform, Load with aggregation

### Implementation
- Create examples showing these patterns
- Document best practices
- Provide templates/generators?

---

## Priority Ranking

### Implement Now
1. **`emit_to_queue(queue_name, item)`** - Unlocks many powerful patterns
2. **Custom Accumulator Logic** - Makes accumulators much more flexible

### Implement Soon
3. **Context Variable** - Improves ergonomics, but workarounds exist
4. **GC Management** - Useful for production, but not critical

### Consider Later
5. **Advanced IPC** - Optimization, needs benchmarks to justify
6. **Advanced Routing Examples** - Documentation/marketing

---

## Implementation Strategy

### Phase 1: Dynamic Routing
1. Implement `emit_to_queue(target, item)` in stage execution
2. Update DAG to support explicit target routing
3. Add validation for target stage existence
4. Add tests for multi-target emission
5. Create example: `39_dynamic_routing.rb`

### Phase 2: Custom Accumulator Logic
1. Allow `emit_to_queue` inside accumulator blocks
2. Support multiple internal buffers in accumulators
3. Update flush logic to handle custom batching
4. Add tests for property-based batching
5. Create example: `40_custom_accumulator.rb`

### Phase 3: Context Variable
1. Expose `context` variable in stage blocks
2. Ensure it works with `instance_exec`
3. Document caveats and best practices
4. Update examples to use `context` where appropriate

---

## Open Questions

1. **`emit_to_queue` vs `emit(item, to: :stage_name)`** - Which syntax?
2. **Context variable name** - `context`? `pipeline`? `self`?
3. **Accumulator custom logic** - New API or just document current flexibility?
4. **IPC compression** - Worth the complexity?

---

## Examples Found in lib_old

- `load_balancer_example.rb` - Round-robin routing with `emit_to_queue`
- `priority_processing_example.rb` - Priority routing and custom accumulator
- `queue_based_routing_example.rb` - Message type routing
- `web_crawler_example.rb` - Recursive crawling with `context` access
- `data_etl_example.rb` - ETL pattern with category-based aggregation

