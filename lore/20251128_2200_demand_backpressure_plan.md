# Demand-Based Backpressure Implementation Plan

**Date:** 2025-11-28
**Feature:** GenStage-style demand handling for Minigun

## Executive Summary

Implement a pull-based demand system inspired by [GenStage](https://hexdocs.pm/gen_stage/GenStage.html) (Elixir) and [Reactive Streams](https://www.reactive-streams.org/). Consumers will explicitly request items from upstream producers using a demand token system with `min_demand`/`max_demand` watermarks.

## Research Summary

### GenStage Demand Model

GenStage uses a **pull-based backpressure** model where:

1. **Consumers send demand upstream** - they request N items
2. **Producers track pending demand** - they never emit more than requested
3. **Watermark thresholds** control when to request more:
   - `max_demand` (default 1000): Maximum items to request at once
   - `min_demand` (default 500): Threshold to request more items
   - When pending demand drops below `min_demand`, consumer requests `max_demand - pending_demand` more

### How GenStage Watermarks Work

```
Initial: Consumer requests max_demand (1000) items
         Pending demand = 1000

Step 1:  Producer sends 100 items → Pending demand = 900
Step 2:  Producer sends 100 items → Pending demand = 800
...
Step 5:  Producer sends 100 items → Pending demand = 500 (hit min_demand!)
         Consumer automatically requests 500 more → Pending demand = 1000
```

This creates a **steady-state batch size** of `max_demand - min_demand` items.

### Key GenStage Concepts to Implement

1. **Demand tracking per subscription** - each consumer-producer pair has independent demand
2. **Automatic demand replenishment** - when pending < min_demand, request more
3. **Event buffering** - producers buffer events when no demand available
4. **Dispatcher strategies** - how to distribute demand across multiple consumers

### Current Minigun Architecture

Minigun currently uses **passive SizedQueue backpressure**:
- Queues have bounded size (default 1000)
- Producers block when queue is full
- No explicit demand signaling
- No metrics on backpressure events

**Key integration points:**
- `InputQueue.pop()` - where consumers pull items
- `OutputQueue.<<()` - where producers push items
- `StageContext` - carries stage execution context
- `Worker.run()` - stage lifecycle management

---

## Implementation Plan

### Phase 1: Core Demand Infrastructure

#### 1.1 Create DemandTracker Class

New file: `lib/minigun/demand/tracker.rb`

```ruby
module Minigun
  module Demand
    class Tracker
      attr_reader :pending_demand, :min_demand, :max_demand

      def initialize(min_demand: 500, max_demand: 1000)
        @min_demand = min_demand
        @max_demand = max_demand
        @pending_demand = 0
        @mutex = Mutex.new
        @demand_available = ConditionVariable.new
      end

      # Consumer calls this to add demand (request items)
      def add_demand(count)
        @mutex.synchronize do
          @pending_demand += count
          @demand_available.broadcast
        end
      end

      # Producer calls this before emitting - blocks if no demand
      def acquire(count = 1, timeout: nil)
        @mutex.synchronize do
          deadline = timeout ? Time.now + timeout : nil

          while @pending_demand < count
            if deadline
              remaining = deadline - Time.now
              return false if remaining <= 0
              @demand_available.wait(@mutex, remaining)
            else
              @demand_available.wait(@mutex)
            end
          end

          @pending_demand -= count
          true
        end
      end

      # Check if demand replenishment needed (for consumers)
      def should_request_more?
        @mutex.synchronize { @pending_demand < @min_demand }
      end

      # Calculate how much to request
      def demand_to_request
        @mutex.synchronize { @max_demand - @pending_demand }
      end

      # Non-blocking check of available demand
      def available_demand
        @mutex.synchronize { @pending_demand }
      end
    end
  end
end
```

#### 1.2 Create DemandChannel Class

Communication channel between consumer and producer for demand signals.

New file: `lib/minigun/demand/channel.rb`

```ruby
module Minigun
  module Demand
    class Channel
      def initialize(producer_stage, consumer_stage, config = {})
        @producer_stage = producer_stage
        @consumer_stage = consumer_stage
        @tracker = Tracker.new(
          min_demand: config[:min_demand] || 500,
          max_demand: config[:max_demand] || 1000
        )
        @closed = false
      end

      # Consumer side: request items
      def request(count)
        return if @closed
        @tracker.add_demand(count)
      end

      # Producer side: wait for demand before emitting
      def wait_for_demand(count = 1, timeout: nil)
        return false if @closed
        @tracker.acquire(count, timeout: timeout)
      end

      # Check if consumer should request more
      def should_replenish?
        @tracker.should_request_more?
      end

      # Get demand replenishment amount
      def replenishment_amount
        @tracker.demand_to_request
      end

      # Close the channel (on completion/error)
      def close
        @closed = true
        @tracker.add_demand(Float::INFINITY) # Unblock waiters
      end

      def closed?
        @closed
      end
    end
  end
end
```

#### 1.3 Create DemandRegistry

Manages demand channels between stages.

New file: `lib/minigun/demand/registry.rb`

```ruby
module Minigun
  module Demand
    class Registry
      def initialize
        @channels = {} # { [producer, consumer] => Channel }
        @mutex = Mutex.new
      end

      def register(producer_stage, consumer_stage, config = {})
        key = [producer_stage, consumer_stage]
        @mutex.synchronize do
          @channels[key] ||= Channel.new(producer_stage, consumer_stage, config)
        end
      end

      def channel_for(producer_stage, consumer_stage)
        @mutex.synchronize { @channels[[producer_stage, consumer_stage]] }
      end

      def channels_from_producer(producer_stage)
        @mutex.synchronize do
          @channels.select { |(p, _c), _| p == producer_stage }.values
        end
      end

      def channels_to_consumer(consumer_stage)
        @mutex.synchronize do
          @channels.select { |(_p, c), _| c == consumer_stage }.values
        end
      end

      def close_all
        @mutex.synchronize do
          @channels.each_value(&:close)
        end
      end
    end
  end
end
```

---

### Phase 2: Integrate with Queue Wrappers

#### 2.1 Create DemandAwareInputQueue

Wraps InputQueue with demand signaling.

```ruby
module Minigun
  class DemandAwareInputQueue
    def initialize(queue, stage, expected_sources, stage_stats: nil, demand_channels: [])
      @inner = InputQueue.new(queue, stage, expected_sources, stage_stats: stage_stats)
      @demand_channels = demand_channels
      @items_since_replenish = 0
    end

    def pop
      item = @inner.pop

      # Track consumption for demand replenishment
      unless item.is_a?(EndOfStage)
        @items_since_replenish += 1
        maybe_replenish_demand
      end

      item
    end

    private

    def maybe_replenish_demand
      @demand_channels.each do |channel|
        if channel.should_replenish?
          amount = channel.replenishment_amount
          channel.request(amount)
          @items_since_replenish = 0
        end
      end
    end
  end
end
```

#### 2.2 Create DemandAwareOutputQueue

Wraps OutputQueue with demand gating.

```ruby
module Minigun
  class DemandAwareOutputQueue
    def initialize(stage, downstream_queues, runtime_edges, stage_stats: nil,
                   demand_channels: [], demand_mode: :auto)
      @inner = OutputQueue.new(stage, downstream_queues, runtime_edges, stage_stats: stage_stats)
      @demand_channels = demand_channels
      @demand_mode = demand_mode # :auto, :manual, :disabled
    end

    def <<(item)
      wait_for_demand if @demand_mode == :auto
      @inner << item
      self
    end

    def to(target)
      # Return wrapper that also respects demand
      DemandAwareTargetedOutputQueue.new(@inner.to(target), @demand_channels, @demand_mode)
    end

    def to_proc
      @inner.to_proc
    end

    private

    def wait_for_demand
      return if @demand_channels.empty?

      # Wait on any channel (first available)
      @demand_channels.each do |channel|
        return if channel.wait_for_demand(1, timeout: 0.001)
      end

      # If no immediate demand, wait on first channel
      @demand_channels.first&.wait_for_demand(1)
    end
  end
end
```

---

### Phase 3: DSL and Configuration

#### 3.1 Add Demand Configuration to Stage DSL

Update `lib/minigun/stage.rb`:

```ruby
class Stage
  stage_option :demand_mode, default: :auto      # :auto, :manual, :disabled
  stage_option :min_demand, type: Integer        # Threshold to request more
  stage_option :max_demand, type: Integer        # Max items to request at once
end
```

#### 3.2 Add Global Configuration

Update `lib/minigun/configuration.rb`:

```ruby
class Configuration
  attr_accessor :demand_enabled          # Enable/disable demand system (default: false)
  attr_accessor :default_min_demand      # Default min_demand (default: 500)
  attr_accessor :default_max_demand      # Default max_demand (default: 1000)
  attr_accessor :demand_timeout          # Timeout for demand wait (default: nil = infinite)
end
```

#### 3.3 DSL Sugar for Demand Control

```ruby
# Enable demand-based backpressure for entire pipeline
pipeline demand: true do
  producer :source do |output|
    # ...
  end

  # Stage with custom demand settings
  consumer :processor, min_demand: 100, max_demand: 500 do |item, output|
    # ...
  end

  # Manual demand control
  consumer :manual_stage, demand_mode: :manual do |item, output, demand:|
    # Process item
    output << result
    # Explicitly request more when ready
    demand.request(10)
  end
end
```

---

### Phase 4: Wire Up Pipeline Execution

#### 4.1 Create Demand Channels During Pipeline Setup

Update `lib/minigun/pipeline.rb`:

```ruby
def build_demand_channels
  return unless @config[:demand_enabled]

  @demand_registry = Demand::Registry.new

  dag.edges.each do |producer, consumers|
    consumers.each do |consumer|
      config = {
        min_demand: consumer.min_demand || Minigun.default_min_demand,
        max_demand: consumer.max_demand || Minigun.default_max_demand
      }
      @demand_registry.register(producer, consumer, config)
    end
  end
end
```

#### 4.2 Pass Demand Channels to Workers

Update `lib/minigun/worker.rb`:

```ruby
def create_stage_context
  # ... existing code ...

  demand_channels = if demand_enabled?
    @pipeline.demand_registry&.channels_to_consumer(@stage) || []
  else
    []
  end

  # Wrap queues with demand awareness
  input_queue = wrap_input_queue_with_demand(raw_input_queue, demand_channels)
  output_queue = wrap_output_queue_with_demand(raw_output_queue, producer_channels)

  StageContext.new(
    # ... existing fields ...
    demand_channels: demand_channels
  )
end
```

#### 4.3 Initialize Demand on Startup

Consumers need to send initial demand when pipeline starts:

```ruby
def initialize_demand(stage_ctx)
  return unless demand_enabled?

  stage_ctx.demand_channels.each do |channel|
    channel.request(channel.max_demand) # Initial demand
  end
end
```

---

### Phase 5: Statistics and Monitoring

#### 5.1 Add Demand Metrics to Stats

Update `lib/minigun/stats.rb`:

```ruby
class StageStats
  attr_reader :demand_wait_count      # Times producer waited for demand
  attr_reader :demand_wait_duration   # Total time waiting for demand
  attr_reader :demand_requests        # Number of demand requests sent
  attr_reader :demand_fulfilled       # Number of demand tokens consumed

  def record_demand_wait(duration)
    @demand_wait_count += 1
    @demand_wait_duration += duration
  end
end
```

#### 5.2 Update HUD Display

Add demand metrics to HUD stats display:

```
Stage: processor
  Throughput: 1,234/s
  Latency: P50=2ms P95=15ms
  Demand: pending=450 waits=12 wait_time=0.3s
```

---

### Phase 6: Advanced Features

#### 6.1 Manual Demand Mode

For fine-grained control, stages can manage demand manually:

```ruby
consumer :careful_processor, demand_mode: :manual do |item, output|
  result = expensive_operation(item)
  output << result

  # Only request more if system is healthy
  if system_healthy?
    demand.request(10)
  else
    demand.request(1) # Slow down
  end
end
```

#### 6.2 Demand Dispatcher Strategies

Like GenStage's dispatchers, support different distribution strategies:

1. **DemandDispatcher** (default): Send to consumer with highest demand
2. **BroadcastDispatcher**: Send to all consumers (each needs separate demand)
3. **PartitionDispatcher**: Route by partition key

```ruby
producer :source, dispatcher: :demand do |output|
  # Events go to consumer with most demand
end

producer :events, dispatcher: :broadcast do |output|
  # Events replicated to all consumers
end

producer :orders, dispatcher: { partition: ->(order) { order.region } } do |output|
  # Events partitioned by region
end
```

#### 6.3 Accumulate/Forward Modes

Like GenStage's demand accumulation:

```ruby
# Accumulate demand until all consumers ready
producer :coordinated, demand_mode: :accumulate do |output|
  # Demand buffered until demand.forward! called
  wait_for_all_consumers_ready
  demand.forward!  # Start flowing

  items.each { |item| output << item }
end
```

---

## File Changes Summary

### New Files

| File | Purpose |
|------|---------|
| `lib/minigun/demand/tracker.rb` | Core demand counting logic |
| `lib/minigun/demand/channel.rb` | Producer-consumer demand channel |
| `lib/minigun/demand/registry.rb` | Manages all demand channels |
| `lib/minigun/demand/dispatcher.rb` | Dispatcher strategies |
| `lib/minigun/demand_aware_queue.rb` | Demand-aware queue wrappers |
| `spec/unit/demand/tracker_spec.rb` | Tracker tests |
| `spec/unit/demand/channel_spec.rb` | Channel tests |
| `spec/integration/demand_backpressure_spec.rb` | Integration tests |

### Modified Files

| File | Changes |
|------|---------|
| `lib/minigun/configuration.rb` | Add demand config options |
| `lib/minigun/stage.rb` | Add demand-related stage options |
| `lib/minigun/pipeline.rb` | Create demand channels, wire up |
| `lib/minigun/worker.rb` | Initialize demand, wrap queues |
| `lib/minigun/stats.rb` | Add demand metrics |
| `lib/minigun/hud/stats_aggregator.rb` | Display demand stats |
| `lib/minigun.rb` | Require new demand modules |

---

## Testing Strategy

### Unit Tests

1. **DemandTracker**: Test add_demand, acquire, watermark logic
2. **DemandChannel**: Test request/wait flow, closure
3. **DemandRegistry**: Test channel lookup, multi-stage graphs
4. **DemandAwareQueues**: Test blocking behavior, throughput

### Integration Tests

1. **Basic demand flow**: Producer waits for consumer demand
2. **Watermark replenishment**: Demand auto-replenished at min_demand
3. **Multi-consumer**: Demand distributed correctly
4. **Pipeline completion**: Demand channels close cleanly
5. **Manual mode**: Explicit demand control works
6. **Mixed modes**: Some stages with demand, some without

### Performance Tests

1. **Throughput comparison**: Demand vs. SizedQueue backpressure
2. **Latency under load**: Demand response time
3. **Memory usage**: Buffer sizes with demand limiting

---

## Migration Path

### Backward Compatibility

- Demand is **opt-in** via `demand: true` config
- Default behavior unchanged (SizedQueue backpressure)
- Existing pipelines work without modification

### Gradual Adoption

```ruby
# Phase 1: Enable globally
Minigun.configure { |c| c.demand_enabled = true }

# Phase 2: Fine-tune per-stage
consumer :bottleneck, max_demand: 100 do |item|
  # Tighter backpressure
end

# Phase 3: Advanced patterns
producer :adaptive, demand_mode: :manual do |output, demand:|
  # Full control
end
```

---

## Open Questions

1. **IPC Fork Compatibility**: How to propagate demand signals across process boundaries?
   - Option A: Marshal demand over IPC pipes
   - Option B: Parent process manages demand, workers just consume

2. **Nested Pipelines**: How should demand flow through PipelineStage?
   - Option A: Transparent pass-through
   - Option B: Each nested pipeline has independent demand

3. **Dynamic Routing**: How does `output.to(:stage)` interact with demand?
   - Each routed target needs its own demand channel

4. **Timeout Behavior**: What happens when demand times out?
   - Return false? Raise exception? Drop item?

---

## Success Criteria

1. **Functional**: Demand gating prevents producer overflow
2. **Performance**: No significant throughput regression vs. SizedQueue
3. **Observability**: Demand metrics visible in HUD and stats
4. **Compatibility**: Existing pipelines unaffected
5. **Testability**: Comprehensive test coverage

---

## References

- [GenStage Documentation](https://hexdocs.pm/gen_stage/GenStage.html)
- [GenStage GitHub](https://github.com/elixir-lang/gen_stage)
- [Reactive Streams Spec](https://www.reactive-streams.org/)
- [Elixir Forum: min_demand/max_demand](https://elixirforum.com/t/could-you-explain-min-demand-and-max-demand-in-genstage/25625)
- [Concurrent-Ruby Channels](https://ruby-concurrency.github.io/concurrent-ruby/1.1.5/Concurrent/Promises/Channel.html)
- [Backpressure Explained](https://medium.com/@jayphelps/backpressure-explained-the-flow-of-data-through-software-2350b3e77ce7)
