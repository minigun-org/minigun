# Cluster Examples

This directory contains comprehensive examples demonstrating various cluster topologies and patterns for distributed execution with Minigun.

## Quick Start

### Basic Example
```bash
# Terminal 1: Start coordinator
ruby examples/110_cluster_coordinator.rb

# Terminal 2: Start worker
ruby examples/111_cluster_worker.rb
```

## Example Index

### 110-111: Basic Clustering
**Files**: `110_cluster_coordinator.rb`, `111_cluster_worker.rb`

Simple coordinator-worker pattern. The coordinator runs a pipeline and distributes CPU-intensive work to workers.

**Topology**:
```
Coordinator (port 9000)
    ↓
Workers (connect to coordinator)
```

**Usage**:
```bash
ruby examples/110_cluster_coordinator.rb  # Terminal 1
ruby examples/111_cluster_worker.rb       # Terminal 2-N (multiple workers)
```

---

### 112: Multi-Stage Cluster
**File**: `112_multi_stage_cluster.rb`

Demonstrates multiple cluster stages in sequence, each with its own worker pool. Shows how to chain different distributed processing steps.

**Topology**:
```
Producer (local)
    ↓
Cluster A: preprocessing (port 9000)
    ↓
Cluster B: heavy_compute (port 9001)
    ↓
Cluster C: postprocessing (port 9002)
    ↓
Consumer (local)
```

**Usage**:
```bash
ruby examples/112_multi_stage_cluster.rb coordinator         # Terminal 1
ruby examples/112_multi_stage_cluster.rb worker_preprocess   # Terminal 2
ruby examples/112_multi_stage_cluster.rb worker_compute      # Terminal 3
ruby examples/112_multi_stage_cluster.rb worker_postprocess  # Terminal 4
```

**Use Case**: ETL pipelines with distinct processing phases, each requiring different resources or scaling independently.

---

### 113: Hierarchical Cluster
**File**: `113_hierarchical_cluster.rb`

Workers can delegate work to sub-clusters, creating a hierarchical topology. Parent workers aggregate results from child workers.

**Topology**:
```
Parent Coordinator (port 9000)
    ↓
Parent Workers
    ↓
Child Coordinators (port 9100, 9101)
    ↓
Child Workers
```

**Usage**:
```bash
# Start child coordinators
ruby examples/113_hierarchical_cluster.rb child_coordinator 9100  # Terminal 1
ruby examples/113_hierarchical_cluster.rb child_coordinator 9101  # Terminal 2

# Start child workers
ruby examples/113_hierarchical_cluster.rb child_worker 9100       # Terminal 3
ruby examples/113_hierarchical_cluster.rb child_worker 9101       # Terminal 4

# Start parent workers
ruby examples/113_hierarchical_cluster.rb parent_worker 9100      # Terminal 5
ruby examples/113_hierarchical_cluster.rb parent_worker 9101      # Terminal 6

# Start parent coordinator
ruby examples/113_hierarchical_cluster.rb parent_coordinator      # Terminal 7
```

**Use Case**: MapReduce-style workflows where workers need to fan out sub-tasks and aggregate results, or multi-tier data centers.

---

### 114: Fan-Out / Fan-In
**File**: `114_cluster_fan_out_fan_in.rb`

Diamond topology where work is routed to specialized clusters based on task type, then results converge for aggregation.

**Topology**:
```
        Producer
            ↓
        Router
       /      \
Cluster A   Cluster B
(GPU/image) (CPU/text)
port 9000   port 9001
       \      /
      Aggregator
```

**Usage**:
```bash
ruby examples/114_cluster_fan_out_fan_in.rb coordinator    # Terminal 1
ruby examples/114_cluster_fan_out_fan_in.rb worker_image   # Terminal 2-N (GPU workers)
ruby examples/114_cluster_fan_out_fan_in.rb worker_text    # Terminal M (CPU workers)
```

**Use Case**: Heterogeneous workloads requiring different hardware (GPUs vs CPUs), or routing to specialized processing clusters.

---

### 115: Hybrid Local + Cluster
**File**: `115_hybrid_local_cluster.rb`

Mixes local execution (threads/forks) with cluster execution in a single pipeline. Demonstrates optimal strategy selection.

**Topology**:
```
Producer (local)
    ↓
Fetch URLs (local threads - I/O)
    ↓
Parse HTML (cluster - CPU-intensive)
    ↓
Extract Data (local forks - small CPU)
    ↓
Save Results (local threads - I/O)
```

**Usage**:
```bash
ruby examples/115_hybrid_local_cluster.rb coordinator  # Terminal 1
ruby examples/115_hybrid_local_cluster.rb worker       # Terminal 2-N
```

**Strategy Guide**:
- **Local threads**: I/O-bound tasks (network, database, disk)
- **Local forks**: CPU-bound tasks (small scale, single machine)
- **Cluster**: CPU-bound tasks (large scale, multiple machines)

**Use Case**: Web scraping, data pipelines where different stages have different bottlenecks.

---

### 116: Peer-to-Peer Cluster
**File**: `116_peer_to_peer_cluster.rb`

Workers communicate directly with each other (peer-to-peer) for large data transfers, bypassing the coordinator.

**Topology**:
```
Coordinator (distributes tasks only)
    ↓
Worker A (owns data shard 0-4)  ←→  Worker B (owns data shard 5-9)
port 9010                            port 9011
```

**Usage**:
```bash
ruby examples/116_peer_to_peer_cluster.rb coordinator   # Terminal 1
ruby examples/116_peer_to_peer_cluster.rb worker 0 9010 # Terminal 2 (shard 0-4)
ruby examples/116_peer_to_peer_cluster.rb worker 5 9011 # Terminal 3 (shard 5-9)
```

**Use Case**: Distributed joins, data shuffling, reduce phases where workers need to exchange large amounts of data.

---

### 117: Circular Loopback
**File**: `117_cluster_loopback.rb`

Demonstrates circular cluster topology where work flows A → B → C → back to A. Node C sends processed results back to a receiving stage in Node A.

**Topology**:
```
┌──────────────────────────────────────┐
│                                      │
▼                                      │
Node A (port 9000)                     │
- initial_process                      │
- final_collect ◄──────────────────────┤
    │                                  │
    ▼                                  │
Node B (port 9001)                     │
- transform                            │
    │                                  │
    ▼                                  │
Node C (port 9002)                     │
- validate_and_loopback ───────────────┘
```

**Usage**:
```bash
# Start in this order:
ruby examples/117_cluster_loopback.rb coordinator_b  # Terminal 1
ruby examples/117_cluster_loopback.rb coordinator_c  # Terminal 2
ruby examples/117_cluster_loopback.rb worker_b       # Terminal 3
ruby examples/117_cluster_loopback.rb worker_c       # Terminal 4
ruby examples/117_cluster_loopback.rb worker_a       # Terminal 5
ruby examples/117_cluster_loopback.rb coordinator_a  # Terminal 6 (last!)
```

**Use Cases**:
- Iterative algorithms (run until convergence)
- Multi-pass processing (refine results through rounds)
- Feedback loops (validate → correct → re-validate)
- Ring topologies for distributed consensus

---

## Common Patterns

### 1. Sequential Cluster Stages
```ruby
in_cluster(coordinator: 'druby://0.0.0.0:9000', min_workers: 2) do
  processor :stage1 do |item, output|
    # Process and forward to next stage
  end
end

in_cluster(coordinator: 'druby://0.0.0.0:9001', min_workers: 3) do
  processor :stage2 do |item, output|
    # Different cluster for different resources
  end
end
```

### 2. Parallel Cluster Branches
```ruby
processor :route do |item, output|
  if item[:type] == :heavy
    output.to(:heavy_cluster) << item
  else
    output.to(:light_cluster) << item
  end
end

in_cluster(coordinator: 'druby://0.0.0.0:9000', min_workers: 10) do
  processor :heavy_cluster do |item, output|
    # Intensive processing
  end
end

in_cluster(coordinator: 'druby://0.0.0.0:9001', min_workers: 2) do
  processor :light_cluster do |item, output|
    # Light processing
  end
end
```

### 3. Worker-to-Worker Communication
```ruby
# In worker code
worker.register_stage(:process) do |item, output|
  # Fetch data from peer worker
  peer = DRbObject.new_with_uri('druby://peer-worker:9010')
  peer_data = peer.get_data(item[:id])

  # Process combined data
  result = compute(item, peer_data)
  output.call(result)
end
```

### 4. Hybrid Execution
```ruby
in_threads(10) do
  processor :io_bound do |item, output|
    # I/O: Use threads for concurrency
  end
end

in_cluster(coordinator: 'druby://0.0.0.0:9000', min_workers: 5) do
  processor :cpu_bound do |item, output|
    # CPU: Use cluster for distribution
  end
end
```

## Performance Tips

1. **Batch Small Items**: If items are < 1KB, batch them together to reduce network overhead
2. **Collocate Related Work**: Use routing to keep related items on same worker
3. **Worker Count**: Start with 1 worker per CPU core across all machines
4. **Monitor Queues**: Check coordinator queue depth - if growing, add workers
5. **Network Bandwidth**: Profile network usage - if saturated, reduce item size
6. **Peer-to-Peer**: For large data exchanges (>10MB), use worker-to-worker communication

## Troubleshooting

### Workers Can't Connect
```
DRb::DRbConnError: connection failed
```
- Check coordinator is running first
- Verify firewall allows port 9000
- Use correct coordinator IP (not 0.0.0.0 from worker)

### Slow Performance
- Check network latency between machines
- Profile item serialization size
- Ensure worker count matches workload
- Consider batching small items

### Out of Memory
- Reduce `min_workers` to process fewer items concurrently
- Implement streaming if processing large files
- Add backpressure with demand tracking

## Advanced Topics

### Dynamic Worker Scaling
Start/stop workers during execution:
```bash
# Add more workers anytime
ruby examples/111_cluster_worker.rb  # New worker connects automatically
```

### Health Monitoring
Check worker heartbeats in coordinator:
```ruby
coordinator.workers.each do |id, info|
  puts "#{id}: last heartbeat #{Time.now - info[:last_heartbeat]}s ago"
end
```

### Load Balancing
Workers use pull-based model - fast workers automatically get more work.

### Failure Handling
Currently no automatic retry. If worker fails, work is lost. Plan: add work retry queue.

## See Also

- [Clustering Guide](../docs/guides/17_clustering.md) - Full documentation
- [Execution Strategies](../docs/guides/06_execution_strategies.md) - Local execution options
- [Performance Tuning](../docs/guides/11_performance_tuning.md) - Optimization tips
