# Demand-Based Backpressure

Minigun supports a pull-based demand system inspired by [Elixir's GenStage](https://hexdocs.pm/gen_stage/GenStage.html). This provides fine-grained control over data flow and prevents fast producers from overwhelming slow consumers.

## Overview

### What is Demand?

In traditional push-based systems, producers emit data as fast as possible, and queues buffer the data. This can lead to:
- Memory exhaustion if queues grow too large
- Unpredictable latency as items wait in queues
- No feedback to producers about consumer capacity

**Demand-based backpressure** inverts this model:
- Consumers explicitly **request** items (demand)
- Producers only emit when demand is available
- Data flow is controlled by the slowest consumer

### How It Works

1. Consumer requests N items from upstream (adds demand)
2. Producer waits for demand before emitting
3. When producer emits, it consumes demand tokens
4. When consumer's pending demand drops below threshold, it requests more

```
Consumer requests 1000 items → Pending demand = 1000
Producer sends 100 items    → Pending demand = 900
Producer sends 100 items    → Pending demand = 800
...
Producer sends 100 items    → Pending demand = 500 (hit min_demand!)
Consumer auto-requests 500  → Pending demand = 1000
```

## Enabling Demand

### Pipeline-Level

Enable demand for the entire pipeline:

```ruby
class MyPipeline
  include Minigun::DSL

  pipeline demand: true do
    producer :source do |output|
      1000.times { |i| output << i }
    end

    consumer :sink do |item|
      process(item)
    end
  end
end
```

### Global Configuration

Enable demand globally for all pipelines:

```ruby
Minigun.configure do |c|
  c.demand_enabled = true
  c.default_min_demand = 500   # Request more when below this
  c.default_max_demand = 1000  # Max items to request at once
end
```

## Demand Settings

### min_demand and max_demand

Control the watermark thresholds per stage:

```ruby
pipeline demand: true do
  producer :source do |output|
    1000.times { |i| output << i }
  end

  # Tight backpressure: small buffer
  consumer :slow_processor, min_demand: 10, max_demand: 25 do |item|
    expensive_operation(item)
  end

  # Loose backpressure: large buffer
  consumer :fast_processor, min_demand: 500, max_demand: 1000 do |item|
    quick_operation(item)
  end
end
```

**Parameters:**
- `min_demand`: Threshold to trigger demand replenishment (default: 500)
- `max_demand`: Maximum items to request at once (default: 1000)

**Batch Size:**
The steady-state batch size is `max_demand - min_demand`. For example, with `min_demand: 500` and `max_demand: 1000`, consumers request 500 items at a time.

### demand_mode Options

Control demand behavior per stage:

```ruby
pipeline demand: true do
  producer :source do |output|
    # ...
  end

  # :auto (default) - automatic demand management
  consumer :stage_a do |item, output|
    output << item
  end

  # :disabled - skip demand tracking for this stage
  consumer :stage_b, demand_mode: :disabled do |item, output|
    output << item
  end
end
```

## Use Cases

### 1. Memory-Constrained Processing

When processing large items that consume significant memory:

```ruby
pipeline demand: true do
  producer :images do |output|
    Dir.glob('*.jpg').each { |path| output << File.read(path) }
  end

  # Only buffer 5 images at a time
  consumer :process, min_demand: 2, max_demand: 5 do |image_data|
    process_image(image_data)  # Memory-intensive
  end
end
```

### 2. Rate-Limited APIs

When calling APIs with rate limits:

```ruby
pipeline demand: true do
  producer :items do |output|
    database.find_each { |item| output << item }
  end

  # Process slowly to respect rate limits
  consumer :api_call, min_demand: 1, max_demand: 10 do |item|
    api.call(item)
    sleep 0.1  # Rate limit: 10/second
  end
end
```

### 3. Cluster Execution with Backpressure

Combine demand with cluster execution:

```ruby
pipeline demand: true do
  producer :source, min_demand: 50, max_demand: 100 do |output|
    100_000.times { |i| output << i }
  end

  in_cluster(worker_uris: worker_uris) do
    processor :compute do |item, output|
      output << expensive_calculation(item)
    end
  end

  # Tight backpressure at the sink
  consumer :sink, min_demand: 10, max_demand: 25 do |item|
    save_to_database(item)
  end
end
```

### 4. Fan-Out with Demand

Demand works with fan-out patterns:

```ruby
pipeline demand: true do
  producer :source, to: %i[fast slow] do |output|
    1000.times { |i| output << i }
  end

  # Fast consumer can handle large batches
  consumer :fast, min_demand: 100, max_demand: 200 do |item|
    quick_process(item)
  end

  # Slow consumer needs tight backpressure
  consumer :slow, min_demand: 5, max_demand: 10 do |item|
    slow_process(item)
  end
end
```

## How Demand Interacts with Queues

### With SizedQueue (Default)

When using `queue_size:` option, you have two layers of backpressure:

1. **Queue backpressure**: Producer blocks when queue is full
2. **Demand backpressure**: Producer blocks when no demand

With demand enabled, the demand system typically kicks in before the queue fills up.

```ruby
# Both queue and demand backpressure
consumer :stage, queue_size: 100, min_demand: 20, max_demand: 50 do |item|
  # ...
end
```

### With Unbounded Queue

Without `queue_size:`, demand provides the only backpressure:

```ruby
# Demand-only backpressure (no queue limit)
consumer :stage, min_demand: 20, max_demand: 50 do |item|
  # ...
end
```

## Demand with Routing Strategies

Demand interacts with routing strategies:

### Broadcast Routing

Each downstream consumer has its own demand channel:

```ruby
pipeline demand: true do
  producer :source, to: %i[a b] do |output|
    # Must satisfy demand from BOTH consumers
    100.times { |i| output << i }
  end

  consumer :a, min_demand: 10, max_demand: 25 do |item|
    # ...
  end

  consumer :b, min_demand: 50, max_demand: 100 do |item|
    # ...
  end
end
```

### Demand Routing

Use `routing: :demand` to route items to consumers with highest demand/capacity:

```ruby
pipeline demand: true do
  producer :source, to: %i[fast slow], routing: :demand do |output|
    100.times { |i| output << i }
  end

  consumer :fast, queue_size: 10 do |item|
    quick_process(item)
  end

  consumer :slow, queue_size: 10 do |item|
    sleep 0.1
    slow_process(item)
  end
end
# Fast consumer gets more items because it has more capacity
```

## Performance Considerations

### When to Use Demand

**Good use cases:**
- Memory-constrained processing
- Rate-limited external calls
- Variable processing speeds across stages
- Need predictable latency

**Consider alternatives if:**
- All stages process at similar speeds
- Items are small and plentiful
- Maximum throughput is the priority (some queue overhead acceptable)

### Tuning Parameters

**Small buffers (`min_demand: 1-10, max_demand: 5-20`):**
- Pros: Tight memory control, predictable latency
- Cons: Higher coordination overhead, potential throughput reduction

**Large buffers (`min_demand: 500-1000, max_demand: 1000-2000`):**
- Pros: Higher throughput, less coordination overhead
- Cons: More memory usage, less responsive to slowdowns

### Monitoring Demand

Demand statistics are available in pipeline stats:

```ruby
pipeline = MyPipeline.new
pipeline.run

# Access demand stats (if stats are enabled)
stats = pipeline.task.stats[:stage_name]
puts "Demand wait count: #{stats.demand_wait_count}"
puts "Demand wait time: #{stats.demand_wait_duration}s"
```

## Comparison with Queue Backpressure

| Feature | Queue Backpressure | Demand Backpressure |
|---------|-------------------|---------------------|
| **Model** | Push (producer-driven) | Pull (consumer-driven) |
| **Control** | Queue size limit | Demand tokens |
| **Memory** | Fixed by queue size | Controlled by max_demand |
| **Latency** | Items wait in queue | Items flow on demand |
| **Overhead** | Lower | Slightly higher |
| **Granularity** | Per-queue | Per-stage |

## Example: Complete Demand Pipeline

```ruby
class DemandExample
  include Minigun::DSL

  attr_reader :results

  def initialize
    @results = []
  end

  pipeline demand: true do
    # Large demand buffer for producer (generates fast)
    producer :source, min_demand: 100, max_demand: 200 do |output|
      puts "Starting production..."
      1000.times { |i| output << { id: i, data: "item-#{i}" } }
      puts "Production complete"
    end

    # Medium buffer for transformer
    consumer :transform, min_demand: 25, max_demand: 50 do |item, output|
      output << item.merge(transformed: true)
    end

    # Tight buffer for slow database writes
    consumer :save, min_demand: 5, max_demand: 10 do |item|
      sleep 0.001  # Simulate slow DB write
      @results << item
    end
  end
end

example = DemandExample.new
example.run
puts "Processed #{example.results.size} items"
```

## Troubleshooting

### Pipeline hangs

**Symptom**: Pipeline stops processing, no errors.

**Possible causes**:
1. Consumer not requesting demand (bug in demand system)
2. Circular dependency causing deadlock
3. Stage not emitting to output

**Solutions**:
- Enable debug logging: `Minigun.logger.level = Logger::DEBUG`
- Check that all stages emit to `output`
- Verify no circular routing

### Slow throughput

**Symptom**: Pipeline processes slowly despite fast stages.

**Possible causes**:
1. Demand buffers too small
2. Demand replenishment overhead

**Solutions**:
- Increase `min_demand` and `max_demand`
- Consider disabling demand for fast stages: `demand_mode: :disabled`

### Memory still growing

**Symptom**: Memory usage increases despite demand settings.

**Possible causes**:
1. Items too large
2. `max_demand` too high
3. Downstream stages accumulating

**Solutions**:
- Reduce `max_demand`
- Process items in smaller chunks
- Check for memory leaks in stage code

## See Also

- [Routing](04_routing.md) - Routing strategies including demand routing
- [Concurrency](05_concurrency.md) - Thread and process pools
- [Clustering](17_clustering.md) - Distributed execution
- [Performance Tuning](11_performance_tuning.md) - Optimization tips
- [Example: Demand Basic](../../examples/29_demand_basic.rb) - Working example
