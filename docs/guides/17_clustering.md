# Clustering and Distributed Execution

Minigun supports distributed execution across multiple machines using Ruby's DRb (Distributed Ruby). This allows you to scale computationally intensive stages across a cluster of worker nodes.

## Overview

Minigun supports two clustering modes:

### Coordinator Mode
- **Coordinator** (Head Node): Runs the pipeline, distributes work to workers
- **Workers** (Compute Nodes): Connect to coordinator, process work items, return results
- Pull-based work distribution (workers request work when ready)
- Automatic load balancing
- Worker heartbeat monitoring

### Direct Mode (No Coordinator)
- Connect directly to a known set of workers
- Work distributed round-robin to workers
- Simpler setup for static worker pools
- No coordinator process needed

Key features:
- Stage code checksum validation for safety
- Support for multiple workers across different machines

## Architecture

```
┌─────────────────┐
│  Coordinator    │  ← Runs your pipeline
│  (Head Node)    │  ← Manages work distribution
└────────┬────────┘
         │ DRb
    ┌────┴────┬─────────┐
    │         │         │
┌───▼───┐ ┌───▼───┐ ┌───▼───┐
│Worker1│ │Worker2│ │Worker3│  ← Process work items
│Machine│ │Machine│ │Machine│  ← Return results
└───────┘ └───────┘ └───────┘
```

### Communication Flow

1. **Setup Phase**:
   - Coordinator starts DRb service on specified port
   - Workers connect and register with coordinator
   - Coordinator validates worker stage checksums

2. **Execution Phase**:
   - Coordinator enqueues work items
   - Workers pull work when ready (non-blocking)
   - Workers process items and return results
   - Coordinator collects results and passes to next stage

3. **Shutdown Phase**:
   - Coordinator sends shutdown signals to workers
   - Workers gracefully disconnect
   - Coordinator stops DRb service

## Basic Usage

### Coordinator Mode (Dynamic Workers)

Use `coordinator_uri:` to run a coordinator that workers connect to:

```ruby
class DistributedPipeline
  include Minigun::DSL

  pipeline do
    # Producer runs on coordinator
    producer :generate do |output|
      1000.times do |i|
        output << { id: i, value: rand(1000) }
      end
    end

    # This stage runs on cluster workers
    in_cluster(
      coordinator_uri: 'druby://0.0.0.0:9000',
      min_workers: 2,
      worker_timeout: 60
    ) do
      processor :compute do |item, output|
        # CPU-intensive computation distributed across workers
        result = expensive_calculation(item[:value])
        output << { id: item[:id], result: result }
      end
    end

    # Consumer runs on coordinator
    consumer :collect do |item|
      puts "Result #{item[:id]}: #{item[:result]}"
    end
  end
end
```

### Direct Mode (Static Workers)

Use `worker_uris:` to connect directly to a known set of workers (no coordinator):

```ruby
class DirectModePipeline
  include Minigun::DSL

  pipeline do
    producer :generate do |output|
      1000.times do |i|
        output << { id: i, value: rand(1000) }
      end
    end

    # Connect directly to workers (round-robin distribution)
    in_cluster(
      worker_uris: [
        'druby://192.168.1.10:9001',
        'druby://192.168.1.11:9001',
        'druby://192.168.1.12:9001'
      ]
    ) do
      processor :compute do |item, output|
        result = expensive_calculation(item[:value])
        output << { id: item[:id], result: result }
      end
    end

    consumer :collect do |item|
      puts "Result #{item[:id]}: #{item[:result]}"
    end
  end
end
```

### Running the Coordinator

The coordinator runs your pipeline on the head node:

```ruby
# coordinator.rb
require 'minigun'

Minigun.logger.level = Logger::INFO

pipeline = DistributedPipeline.new
pipeline.run
```

Start the coordinator:
```bash
ruby coordinator.rb
```

### Running Workers

**Method 1: Manual Worker Registration** (Current Implementation)

Create a worker script that manually registers stage processors:

```ruby
# worker.rb
require 'minigun'

COORDINATOR_URI = ENV.fetch('COORDINATOR_URI', 'druby://coordinator-host:9000')

worker = Minigun::Cluster::Worker.new(
  coordinator_uri: COORDINATOR_URI
)

# Register stage processors (must match coordinator's pipeline)
worker.register_stage(:compute) do |item, output|
  result = expensive_calculation(item[:value])
  output.call({ id: item[:id], result: result })
end

# Connect and start processing
worker.connect
puts "Worker #{worker.worker_id} connected!"
worker.start
```

Start workers on different machines:
```bash
# On worker machine 1
COORDINATOR_URI=druby://192.168.1.10:9000 ruby worker.rb

# On worker machine 2
COORDINATOR_URI=druby://192.168.1.10:9000 ruby worker.rb
```

**Method 2: Shared Codebase** (Recommended, Coming Soon)

Deploy the same codebase to all machines and run in worker mode:

```ruby
# app.rb - runs on both coordinator and workers
class DistributedPipeline
  include Minigun::DSL

  pipeline do
    producer :generate do |output|
      # ...
    end

    in_cluster(coordinator_uri: 'druby://0.0.0.0:9000', min_workers: 2) do
      processor :compute do |item, output|
        result = expensive_calculation(item[:value])
        output << { id: item[:id], result: result }
      end
    end

    consumer :collect do |item|
      # ...
    end
  end
end

# Run as coordinator OR worker
if ENV['WORKER_MODE']
  DistributedPipeline.run_as_worker(
    coordinator_uri: ENV['COORDINATOR_URI']
  )
else
  DistributedPipeline.new.run
end
```

## Configuration Options

### `in_cluster` Parameters

**Coordinator Mode:**
```ruby
in_cluster(
  coordinator_uri: 'druby://0.0.0.0:9000',  # DRb URI for coordinator
  min_workers: 1,                            # Minimum workers required before starting
  worker_timeout: 30                         # Seconds to wait for minimum workers
) do
  # stages to run on cluster
end
```

**Direct Mode:**
```ruby
in_cluster(
  worker_uris: [                             # Array of worker DRb URIs
    'druby://worker1:9001',
    'druby://worker2:9001',
    'druby://worker3:9001'
  ],
  shutdown_on_done: false                    # Shutdown workers when stage completes (default: false)
) do
  # stages to run on cluster
end
```

**Note:** You must use either `coordinator_uri:` OR `worker_uris:`, not both.

- **coordinator_uri**: DRb URI where coordinator listens (coordinator mode)
  - Use `0.0.0.0` to listen on all interfaces
  - Use `127.0.0.1` for localhost only
  - Use specific IP for specific interface

- **worker_uris**: Array of DRb URIs for direct worker connections (direct mode)
  - Workers must be running before pipeline starts
  - Work is distributed round-robin across workers

- **shutdown_on_done**: Shutdown workers when stage completes (default: false)
  - Only applies to direct mode
  - Use `true` for dedicated workers that should terminate after processing
  - Use `false` (default) for shared worker pools that serve multiple clients

- **min_workers**: Minimum number of workers that must connect before processing starts
  - Default: 1
  - Coordinator will wait up to `worker_timeout` seconds
  - Only applies to coordinator mode

- **worker_timeout**: Maximum seconds to wait for `min_workers` to connect
  - Default: 30
  - Raises error if timeout expires
  - Only applies to coordinator mode

### Worker Options

```ruby
Minigun::Cluster::Worker.new(
  coordinator_uri: 'druby://coordinator-host:9000',  # Required
  worker_id: 'custom-worker-id',                      # Optional, auto-generated if not provided
  stage_registry: {}                                  # Optional, for pre-registering stages
)
```

## Code Deployment

**Important**: Workers must have the same stage code as the coordinator.

When using clustering:
1. Deploy the same codebase to all machines (coordinator + workers)
2. Ensure all machines are running the same version
3. Workers manually register stage processors (current implementation)
4. Future: Automatic worker mode from shared pipeline class (planned)

If worker code doesn't match coordinator, you'll get runtime errors when processing items.

## Discovery Strategies

Minigun supports different strategies for workers to discover coordinators:

### Static Discovery (Default)

Manually configure coordinator URI:

```ruby
worker = Minigun::Cluster::Worker.new(
  coordinator_uri: 'druby://192.168.1.10:9000'
)
```

### Gossip-Based Discovery (Optional)

Using the SWIM protocol via the `rswim` gem:

```ruby
# Add to Gemfile
gem 'rswim'

# Coordinator announces itself
discovery = Minigun::Cluster::Discovery::Gossip.new(
  port: 7946,
  seed_hosts: ['192.168.1.10:7946', '192.168.1.11:7946'],
  encryption_key: ENV['CLUSTER_SECRET']
)

discovery.start
discovery.announce(
  drb_uri: 'druby://0.0.0.0:9000',
  stage: :compute
)

# Workers discover coordinators
workers = discovery.discover
# => [{ host: '192.168.1.10', uri: 'druby://...', stage: :compute }, ...]
```

## Monitoring and Debugging

### Worker Heartbeats

Workers send heartbeats every 5 seconds (configurable):

```ruby
# In Worker class
@heartbeat_interval = 5  # seconds
```

Coordinator tracks last heartbeat time:

```ruby
coordinator.workers.each do |worker_id, info|
  puts "Worker: #{worker_id}"
  puts "  Last heartbeat: #{Time.now - info[:last_heartbeat]}s ago"
  puts "  Registered: #{info[:registered_at]}"
  puts "  Capabilities: #{info[:capabilities]}"
end
```

### Logging

Enable detailed cluster logging:

```ruby
Minigun.logger.level = Logger::DEBUG
```

Log messages include:
- `[Cluster] Coordinator started at druby://...`
- `[Cluster] Worker registered: worker-id at druby://...`
- `[Cluster] Stage checksum validated for worker worker-id`
- `[Cluster] Worker error: ...`
- `[Cluster] Worker unregistered: worker-id`

### Error Handling

Cluster-specific errors:

```ruby
begin
  pipeline.run
rescue Minigun::Cluster::ConnectionError => e
  puts "Failed to connect to coordinator: #{e.message}"
rescue Minigun::Cluster::Error => e
  puts "Cluster error: #{e.message}"
end
```

## Performance Considerations

### Network Overhead

- DRb uses Marshal for serialization
- Small items (< 1KB) have ~1-2ms network overhead
- Large items (> 1MB) may be slower than local processing
- Consider batching small items for better throughput

### Optimal Worker Count

- **CPU-bound work**: workers ≈ total cores across machines
- **I/O-bound work**: workers > cores (can oversubscribe)
- **Mixed workload**: start with cores, tune based on metrics

### Load Balancing

Workers use pull-based model:
- Fast workers automatically get more work
- Slow workers don't become bottlenecks
- No manual work partitioning needed

## Security Considerations

### Network Security

1. **Use private networks**: Run DRb on private VPC/LAN
2. **Firewall rules**: Restrict coordinator port access
3. **Encryption**: DRb doesn't encrypt by default
   - Use VPN or SSH tunnels for untrusted networks
   - Or use gossip discovery with encryption_key

### Code Safety

1. **Checksum validation**: Prevents code mismatch
2. **Shared codebase**: All nodes run same application version
3. **Input validation**: Sanitize data in stage processors
4. **Sandboxing**: Run workers in containers (Docker/Kubernetes)

## Examples

### Example 1: Distributed Web Scraping

```ruby
class WebScraperCluster
  include Minigun::DSL

  pipeline do
    producer :urls do |output|
      File.readlines('urls.txt').each do |url|
        output << { url: url.strip }
      end
    end

    in_cluster(coordinator_uri: 'druby://0.0.0.0:9000', min_workers: 5) do
      processor :scrape do |item, output|
        require 'net/http'
        html = Net::HTTP.get(URI(item[:url]))
        output << { url: item[:url], html: html, size: html.length }
      end
    end

    processor :extract do |item, output|
      # Extract data from HTML...
      data = extract_data(item[:html])
      output << { url: item[:url], data: data }
    end

    consumer :save do |item|
      # Save to database...
    end
  end
end
```

### Example 2: Distributed Image Processing

```ruby
class ImageProcessor
  include Minigun::DSL

  pipeline do
    produce_each :images, Dir.glob('images/*.jpg')

    in_cluster(coordinator_uri: 'druby://0.0.0.0:9000', min_workers: 10) do
      processor :resize do |path, output|
        require 'mini_magick'
        image = MiniMagick::Image.open(path)
        image.resize '800x600'
        output << { path: path, resized: image.path }
      end

      processor :thumbnail do |item, output|
        image = MiniMagick::Image.open(item[:resized])
        image.resize '200x150'
        output << { path: item[:path], thumb: image.path }
      end
    end

    consumer :upload do |item|
      # Upload to S3...
    end
  end
end
```

### Example 3: MapReduce Pattern

```ruby
class WordCount
  include Minigun::DSL

  pipeline do
    produce_each :files, Dir.glob('docs/*.txt')

    # Map phase (distributed)
    in_cluster(coordinator_uri: 'druby://0.0.0.0:9000', min_workers: 4) do
      processor :map do |file, output|
        File.read(file).split.each do |word|
          output << { word: word.downcase, count: 1 }
        end
      end
    end

    # Reduce phase (local accumulator)
    accumulator :reduce, initial: Hash.new(0) do |acc, item|
      acc[item[:word]] += item[:count]
      acc
    end

    consumer :results do |word_counts|
      word_counts.sort_by { |_word, count| -count }.first(10).each do |word, count|
        puts "#{word}: #{count}"
      end
    end
  end
end
```

## Comparison with Other Execution Strategies

| Feature | Threads | IPC Forks | Cluster |
|---------|---------|-----------|---------|
| **Parallelism** | Concurrent | Parallel | Distributed |
| **Overhead** | Low | Medium | High |
| **Isolation** | Shared memory | Process isolation | Machine isolation |
| **Scaling** | 1 machine | 1 machine | Multiple machines |
| **Network** | No | No | Yes (DRb) |
| **Best For** | I/O-bound | CPU-bound | Massive compute |

## Limitations

Current limitations:
1. **Manual stage registration**: Workers must manually register stages (shared codebase mode coming)
2. **No fault tolerance**: Failed workers don't retry work items
3. **No coordinator failover**: Single coordinator is a single point of failure
4. **Marshal only**: Limited to Marshal-serializable data types
5. **No persistent queues**: Work lost if coordinator crashes

Planned improvements:
- Automatic worker mode from shared pipeline class
- Work item retry and dead-letter queue
- Coordinator HA with leader election (optional Raft)
- MessagePack support for broader type compatibility
- Integration with Redis/RabbitMQ for persistent queues

## Troubleshooting

### Workers can't connect

```
Failed to connect: DRb::DRbConnError
```

**Solutions**:
- Check coordinator is running: `netstat -an | grep 9000`
- Verify firewall allows port 9000
- Use correct coordinator IP (not 0.0.0.0 from worker side)
- Check network connectivity: `telnet coordinator-host 9000`

### Workers timeout

```
Timeout waiting for minimum workers
```

**Solutions**:
- Start workers before coordinator
- Increase `worker_timeout` parameter
- Reduce `min_workers` requirement
- Check worker logs for connection errors

### Slow performance

**Diagnosis**:
- Check network latency between machines
- Monitor item size (large items = slow serialization)
- Check worker CPU/memory usage
- Look for bottlenecks in stage code

**Solutions**:
- Batch small items together
- Use faster network (10G ethernet)
- Add more workers
- Optimize stage computation
- Consider local processing if network is bottleneck

## See Also

- [Execution Strategies](06_execution_strategies.md) - Local execution options
- [Concurrency](05_concurrency.md) - Thread and process pools
- [Examples](../../examples/110_cluster_coordinator.rb) - Full cluster examples
