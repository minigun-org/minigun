# Plan: Add DemandRouter and PartitionRouter

## Overview
Add two new routing strategies inspired by GenStage:
1. **DemandRouter**: Routes items to the consumer with the highest outstanding demand
2. **PartitionRouter**: Routes items to consumers based on a hash function for partition affinity

## GenStage Reference

Sources:
- [GenStage.DemandDispatcher docs](https://hexdocs.pm/gen_stage/GenStage.DemandDispatcher.html)
- [GenStage.PartitionDispatcher docs](https://hexdocs.pm/gen_stage/GenStage.PartitionDispatcher.html)
- [GenStage dispatcher source](https://github.com/elixir-lang/gen_stage/blob/main/lib/gen_stage/dispatcher.ex)

### GenStage.DemandDispatcher (default)
- Sends batches to the consumer with the **highest demand** (FIFO ordering)
- Recommendation: "all consumers have exactly the same maximum demand" to avoid greedy consumers
- Options:
  - `:shuffle_demands_on_first_dispatch` - randomizes initial order to prevent overloading first consumer
  - `:max_demand` - maximum demand threshold
- State: `{demands_list, pending, max_demand, shuffle_flag}`
- New consumers added with zero initial demand
- Dispatch logic: consumers with higher demand receive events first

### GenStage.PartitionDispatcher
- Routes events to consumers based on partition assignment via hash function
- Default hash: `:erlang.phash2(event, partition_count)`
- Options:
  - `:partitions` - integer range (0..n) or enumerable list of partition names
  - `:hash` - custom function `fn event -> {event, partition} end` or `:none` to discard
- Consumers must specify `:partition` option when subscribing
- Only ONE consumer per partition allowed
- Uses per-partition queues to buffer when demand insufficient
- **Warning**: "if the data is uneven for long periods of time, then you may buffer excessive data from busy partitions"
- Within each partition, multiple consumers trigger demand-based dispatch

### Key Differences from Our Model
- GenStage uses pull-based demand where consumers request items
- Our model uses push-based with queues (SizedQueue provides backpressure)
- GenStage partitions are named and consumers subscribe to specific partitions
- Our routers distribute to downstream stages automatically

## Current Architecture

### Existing Routers
- `RouterStage` - Base class with common functionality (targets, send_end_signals)
- `RouterBroadcastStage` - Sends each item to ALL downstream stages
- `RouterRoundRobinStage` - Distributes items in round-robin fashion

### Router Selection
Routers are automatically inserted by `Pipeline#insert_router_stages_for_fan_out` when a stage has multiple downstream consumers. The `routing:` option controls which router is used:
- `routing: :broadcast` (default) - RouterBroadcastStage
- `routing: :round_robin` - RouterRoundRobinStage

### Demand System
The existing demand system (`lib/minigun/demand/`) provides:
- `Channel` - Producer-consumer demand signaling
- `Tracker` - Demand token management with min/max thresholds
- `Registry` - Manages demand channels across the pipeline
- `AwareOutputQueue` / `AwareInputQueue` - Queue wrappers with demand integration

## Implementation Plan

### 1. Add RouterDemandStage (`lib/minigun/stage.rb`)

**Approach**: Use the **existing demand system** (`lib/minigun/demand/`) when enabled. The `Demand::Registry` tracks pending demand per producer-consumer pair. When demand is disabled, fall back to queue capacity (SizedQueue) or round-robin.

**Key insight**: We already have pull-based demand implemented (see `lore/20251128_2200_demand_backpressure_plan.md`). The router just needs to query the demand channels.

```ruby
class RouterDemandStage < RouterStage
  # Routes items to consumer with highest pending demand
  # Falls back to queue capacity or round-robin when demand not enabled

  def initialize(name, pipeline, targets, options = {})
    super
    @shuffle_on_first = options[:shuffle_on_first_dispatch] || false
    @first_dispatch = true
    @round_robin_index = 0
  end

  def run_stage(worker_ctx)
    task = worker_ctx.stage.task
    target_info = @targets.map { |t| [t, task&.find_queue(t)] }

    # Get demand registry if demand is enabled
    demand_registry = @pipeline.demand_registry if @pipeline.demand_enabled?

    # Shuffle on first dispatch to avoid overloading first consumer
    target_info.shuffle! if @shuffle_on_first && @first_dispatch
    @first_dispatch = false

    loop do
      item = worker_ctx.input_queue.pop
      break if handle_end_of_source(item, worker_ctx)
      next if handle_routed_item(item, task)

      # Find target with highest demand/capacity
      best_queue = find_best_target(target_info, demand_registry)
      best_queue << item
    end
  ensure
    send_end_signals(worker_ctx)
  end

  private

  def find_best_target(target_info, demand_registry)
    # Strategy 1: Use demand system if enabled
    if demand_registry
      best_target, best_queue = target_info.max_by do |target, _queue|
        # Get demand channel for this router -> target
        channel = demand_registry.channel_for(self, target)
        channel&.pending_demand || 0
      end
      return best_queue if best_target
    end

    # Strategy 2: Use queue capacity for SizedQueue
    sized = target_info.select { |_, q| q.is_a?(SizedQueue) }
    if sized.any?
      _, best = sized.max_by { |_, q| q.max - q.size }
      return best
    end

    # Strategy 3: Round-robin for unbounded queues
    _, queue = target_info[@round_robin_index % target_info.size]
    @round_robin_index += 1
    queue
  end
end
```

**Key considerations:**
- Uses existing `Demand::Registry` when `demand: true` enabled
- Falls back to SizedQueue capacity, then round-robin
- `shuffle_on_first_dispatch:` option (like GenStage) to prevent overloading first consumer
- Thread-safe: demand queries and Queue#size are atomic

### 2. Add RouterPartitionStage (`lib/minigun/stage.rb`)

**Approach**: Use Ruby's `Object#hash` which is consistent within a process. Support custom hash function like GenStage.

```ruby
class RouterPartitionStage < RouterStage
  # Routes items based on hash function for partition affinity
  # Ensures items with same key always go to same consumer

  def initialize(name, pipeline, targets, options = {})
    super
    @partition_count = targets.size
    @hash_fn = build_hash_function(options)
  end

  def run_stage(worker_ctx)
    task = worker_ctx.stage.task
    target_queues = @targets.map { |t| task&.find_queue(t) }

    loop do
      item = worker_ctx.input_queue.pop
      break if handle_end_of_source(item, worker_ctx)
      next if handle_routed_item(item, task)

      # Hash item to partition index
      partition = @hash_fn.call(item)
      next if partition == :none # Discard item (like GenStage)

      target_queues[partition % @partition_count] << item
    end
  ensure
    send_end_signals(worker_ctx)
  end

  private

  def build_hash_function(options)
    partition_key = options[:partition_key]
    custom_hash = options[:hash]

    if custom_hash
      # Custom hash function: ->(item) { partition_index } or :none
      custom_hash
    elsif partition_key.is_a?(Proc)
      # Extract key via proc, then hash
      ->(item) { partition_key.call(item).hash.abs }
    elsif partition_key.is_a?(Symbol)
      # Extract key from hash/object, then hash
      ->(item) {
        key = item.is_a?(Hash) ? item[partition_key] : item.send(partition_key)
        key.hash.abs
      }
    else
      # Default: hash the entire item
      ->(item) { item.hash.abs }
    end
  end
end
```

**Key considerations:**
- `partition_key:` - Symbol (`:user_id`) or Proc (`->(item) { item[:user_id] }`)
- `hash:` - Custom hash function returning partition index or `:none` to discard
- Default: `item.hash.abs % partition_count`
- Use `.abs` to handle negative hash values
- Consistent within process (Ruby's hash is deterministic per-process)

### 3. Update Pipeline Router Selection (`lib/minigun/pipeline.rb`)

```ruby
def insert_router_stages_for_fan_out
  # ...existing code...

  router_stage = case routing_strategy
                 when :round_robin
                   RouterRoundRobinStage.new(router_name, self, downstream.dup, {})
                 when :demand
                   RouterDemandStage.new(router_name, self, downstream.dup, stage.options)
                 when :partition
                   RouterPartitionStage.new(router_name, self, downstream.dup, stage.options)
                 else # :broadcast
                   RouterBroadcastStage.new(router_name, self, downstream.dup, {})
                 end
end
```

### 4. Update DSL (if needed)

Check if DSL needs updates to accept new routing options:
```ruby
producer :source, to: [:a, :b, :c], routing: :demand
producer :source, to: [:a, :b, :c], routing: :partition, partition_key: :user_id
```

### 5. Tests

Create `spec/unit/routers_spec.rb`:

**DemandRouter tests:**
- Routes to consumer with highest demand
- Falls back to round-robin when demands equal
- Works when demand channels not configured
- Handles RoutedItem messages correctly

**PartitionRouter tests:**
- Same key always goes to same partition
- Different keys distribute across partitions
- Works with proc partition_key
- Works with symbol partition_key
- Handles missing partition key gracefully
- Handles RoutedItem messages correctly

### 6. Examples

Create `examples/91_routing_strategies.rb`:
- Demonstrate all four routing strategies
- Show partition routing for user-affinity processing
- Show demand routing for load balancing

## Files to Modify

1. `lib/minigun/stage.rb` - Add RouterDemandStage, RouterPartitionStage
2. `lib/minigun/pipeline.rb` - Update router selection logic
3. `spec/unit/routers_spec.rb` - New test file
4. `examples/91_routing_strategies.rb` - New example

## Dependencies

- DemandRouter needs access to demand registry/channels
- PartitionRouter is self-contained (no external dependencies)

## Design Decisions

1. **DemandRouter uses existing demand system** when enabled:
   - Query `Demand::Registry` for pending demand per target
   - Falls back to SizedQueue capacity when demand disabled
   - Falls back to round-robin for unbounded queues

2. **PartitionRouter uses item.hash by default**:
   - Ruby's Object#hash is consistent within a process
   - Use `.abs` to handle negative values
   - Support `:none` return value to discard items (like GenStage)

3. **Both routers support shuffle_on_first_dispatch**:
   - Prevents overloading first consumer (GenStage best practice)

4. **No need to switch queue models**:
   - We already have both push-based (default) and pull-based (opt-in demand system)
   - Routers work with both models
