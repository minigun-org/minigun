# Routing Strategies Implementation

## Overview

Added two new routing strategies inspired by Elixir's GenStage: **DemandRouter** and **PartitionRouter**. These complement the existing BroadcastRouter (default) and RoundRobinRouter.

## New Router Types

### RouterDemandStage

Routes items to the consumer with the highest outstanding demand or available capacity.

**Strategy (3-tier fallback):**
1. **Demand Registry**: If pipeline has demand enabled (`demand: true`), routes to consumer with highest pending demand
2. **Queue Capacity**: For SizedQueues, routes to queue with most available space (`max - size`)
3. **Round-Robin**: For unbounded queues, falls back to round-robin distribution

**Options:**
- `shuffle_on_first_dispatch: true` - Randomizes target order on first dispatch to prevent thundering herd

**Use cases:**
- Load balancing across consumers with varying processing speeds
- Backpressure-aware routing when using bounded queues

### RouterPartitionStage

Routes items based on a hash function, ensuring items with the same key always go to the same consumer.

**Hash function resolution (priority order):**
1. `hash:` option - Custom lambda returning partition index or `:none` to discard
2. `partition_key:` as Proc - Lambda to extract key, then `.hash.abs`
3. `partition_key:` as Symbol - Extracts key via `item[key]` or `item.send(key)`, then `.hash.abs`
4. Default - Uses `item.hash.abs`

**Options:**
- `partition_key:` - Symbol or Proc to extract partition key from item
- `hash:` - Custom hash function returning partition index (0 to n-1) or `:none`

**Use cases:**
- Maintaining order for items with same key (e.g., user events)
- Stateful processing where same keys must hit same consumer
- Filtering items by returning `:none` from hash function

## Implementation Details

### Files Modified

**lib/minigun/stage.rb**
- Added `RouterDemandStage` class (~60 lines)
- Added `RouterPartitionStage` class (~50 lines)

**lib/minigun/pipeline.rb**
- Updated `insert_router_stages_for_fan_out` to handle `:demand` and `:partition` routing
- Router options (`partition_key`, `hash`, `shuffle_on_first_dispatch`) passed through from stage options

### DSL Usage

```ruby
# Broadcast (default) - sends to ALL consumers
producer :source, to: %i[a b]

# Round-robin - alternates between consumers
producer :source, to: %i[a b], routing: :round_robin

# Demand - routes to consumer with most capacity
producer :source, to: %i[a b], routing: :demand
producer :source, to: %i[a b], routing: :demand, shuffle_on_first_dispatch: true

# Partition - routes by hash for key affinity
producer :source, to: %i[a b], routing: :partition, partition_key: :user_id
producer :source, to: %i[a b], routing: :partition, partition_key: ->(item) { item[:category] }
producer :source, to: %i[a b], routing: :partition, hash: ->(item) { item % 3 }

# Partition with filtering (discard items)
producer :source, to: %i[a b], routing: :partition, hash: ->(item) { item >= 0 ? item % 2 : :none }
```

## GenStage Inspiration

Referenced Elixir GenStage dispatchers:
- **DemandDispatcher**: Routes to consumer with highest demand (FIFO ordering)
- **PartitionDispatcher**: Routes via `:erlang.phash2`, supports custom hash returning `{:ok, idx}` or `:none`

Key differences from GenStage:
- Minigun uses push-based queues by default (opt-in demand via `demand: true`)
- RouterDemandStage has 3-tier fallback (demand → capacity → round-robin)
- Hash function returns index directly or `:none` (not tuple)

## Testing

**spec/unit/routers_spec.rb** - 12 tests covering:
- DemandRouter with SizedQueue (capacity-based routing)
- DemandRouter with unbounded Queue (round-robin fallback)
- DemandRouter shuffle_on_first_dispatch option
- PartitionRouter with symbol partition_key
- PartitionRouter with proc partition_key
- PartitionRouter with custom hash function
- PartitionRouter hash returning `:none` for filtering
- PartitionRouter default hash (item.hash)
- DSL integration for all routing types

**examples/91b_routing_strategies.rb** - Runnable example demonstrating all strategies

## Performance Considerations

- DemandRouter checks demand/capacity on each dispatch (O(n) where n = target count)
- PartitionRouter computes hash once per item (O(1) after hash)
- Both maintain no additional state beyond round-robin index (for DemandRouter fallback)
