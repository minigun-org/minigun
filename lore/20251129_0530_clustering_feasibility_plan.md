# Clustering Support Feasibility Plan

**Date:** 2025-11-29
**Feature:** Distributed clustering across multiple machines (like IPC, but across network)
**Status:** RESEARCH / PLANNING

## Executive Summary

This document analyzes the feasibility of implementing distributed clustering in Minigun, similar to the existing IPC fork pool but spanning multiple machines. The analysis covers how Elixir/OTP handles this, what Ruby primitives are available, whether consensus algorithms like Raft are needed, and the implementation options.

## How Elixir Does It

### Elixir/OTP Distribution Model

Elixir's clustering is built on top of the Erlang/OTP distribution protocol, which has been stable for decades:

1. **EPMD (Erlang Port Mapper Daemon)**: A discovery service running on port 4369 that maps node names to their distribution ports.

2. **Distributed Erlang Protocol**: A binary protocol for node-to-node communication, including:
   - Node handshake and authentication
   - Process message passing
   - Remote process spawning
   - Remote function calls

3. **libcluster**: A library that automates cluster formation using pluggable strategies:
   - **Epmd**: Static list of hosts
   - **Gossip**: UDP multicast heartbeats
   - **Kubernetes**: K8s API-based discovery
   - **DNS**: DNS-based service discovery

### Key Elixir/OTP Advantages

- **Built into the VM**: Distribution is a core VM feature, not a library
- **Location transparency**: `send(pid, msg)` works identically for local/remote
- **Supervision trees**: Automatic restart/recovery across nodes
- **Process registry**: Global process naming (`{:global, :my_process}`)
- **No serialization overhead**: Erlang Term Format (ETF) is native

### Why Elixir Doesn't Need Raft

Erlang/OTP clustering is NOT a consensus system by default:
- No automatic leader election
- No replicated state machine
- No guaranteed consistency across nodes

Instead, it provides **primitives** (message passing, process spawning) that you build upon. For consensus, Elixir users add libraries like:
- **Horde**: Distributed process registry with CRDT-based consistency
- **Swarm**: Simple distributed process registry
- **Ra**: Raft implementation for Erlang/Elixir

## Ruby's Distribution Primitives

### DRb (Distributed Ruby)

Ruby's built-in distribution mechanism:

```ruby
# Server
require 'drb'
class WorkQueue
  def initialize
    @queue = Queue.new
  end
  def push(item); @queue.push(item); end
  def pop; @queue.pop; end
end
DRb.start_service('druby://0.0.0.0:9000', WorkQueue.new)
```

```ruby
# Client
require 'drb'
queue = DRbObject.new_with_uri('druby://server:9000')
queue.push({ item: data })
```

**Pros:**
- Built into Ruby stdlib
- Simple API (looks like local method calls)
- Supports access control lists (ACL)

**Cons:**
- No automatic discovery
- No fault tolerance
- Marshal-based serialization (security concerns)
- Single-threaded server by default
- No built-in load balancing

### Rinda (TupleSpace)

A coordination mechanism built on DRb:

```ruby
# TupleSpace server
require 'rinda/tuplespace'
ts = Rinda::TupleSpace.new
DRb.start_service('druby://0.0.0.0:9001', ts)

# Worker (on any machine)
ts = DRbObject.new_with_uri('druby://server:9001')
loop do
  _, task = ts.take(['task', nil])  # Blocks until task available
  result = process(task)
  ts.write(['result', task[:id], result])
end

# Coordinator
ts.write(['task', { id: 1, data: '...' }])
_, _, result = ts.take(['result', 1, nil])
```

**Pros:**
- Natural work distribution model
- Blocking take/read operations
- Pattern matching on tuples
- Better coordination semantics than raw DRb

**Cons:**
- Single point of failure (central TupleSpace)
- No persistence
- No partitioning/sharding
- All data flows through central server

### BERT/BERTRPC

Binary Erlang Term serialization for Ruby (GitHub uses this):

```ruby
require 'bert'
encoded = BERT.encode({ name: 'John', age: 30 })
decoded = BERT.decode(encoded)
```

Could be used as a serialization layer, but doesn't provide the distribution protocol itself.

## Do We Need Raft?

**Short answer: Not necessarily.**

### When You Need Raft/Consensus

1. **Leader election**: Only one node should perform certain operations
2. **Replicated state**: All nodes must agree on shared state
3. **Linearizability**: Strict ordering of operations across the cluster
4. **Metadata coordination**: Cluster membership, configuration

### When You Don't Need Raft

1. **Stateless work distribution**: Our primary use case!
2. **At-least-once processing**: Retry failed items elsewhere
3. **Eventually consistent results**: Results collected centrally

**For Minigun's use case (distributed pipeline execution), Raft is NOT required** because:
- Workers are stateless (no shared state to replicate)
- Work items are distributed from a coordinator
- Results flow back to coordinator
- If a worker dies, its work can be requeued

### Where Consensus Would Help

If we wanted advanced features:
- **Coordinator failover**: Who becomes coordinator if it dies?
- **Distributed producer**: Multiple nodes producing without duplication
- **Exactly-once semantics**: Preventing duplicate processing

## Implementation Options

### Option 1: Centralized Coordinator (Simplest)

Architecture: Hub and spoke, similar to Ray

```
                    ┌─────────────────┐
                    │   Coordinator   │
                    │  (head node)    │
                    │                 │
                    │  - Task queue   │
                    │  - Result coll  │
                    │  - Worker mgmt  │
                    └────────┬────────┘
                             │
         ┌───────────────────┼───────────────────┐
         │                   │                   │
    ┌────┴────┐        ┌────┴────┐        ┌────┴────┐
    │ Worker  │        │ Worker  │        │ Worker  │
    │ Node 1  │        │ Node 2  │        │ Node 3  │
    └─────────┘        └─────────┘        └─────────┘
```

**Implementation:**
```ruby
# Coordinator
class ClusterCoordinator
  def initialize(bind_address:)
    @work_queue = Queue.new
    @result_queue = Queue.new
    @workers = {}
    DRb.start_service(bind_address, self)
  end

  def register_worker(worker_uri)
    @workers[worker_uri] = DRbObject.new_with_uri(worker_uri)
  end

  def request_work
    @work_queue.pop(true) rescue nil
  end

  def submit_result(result)
    @result_queue.push(result)
  end
end

# Worker
class ClusterWorker
  def initialize(coordinator_uri:, stage_proc:)
    @coordinator = DRbObject.new_with_uri(coordinator_uri)
    @stage_proc = stage_proc
    DRb.start_service(nil, self)
    @coordinator.register_worker(DRb.uri)
  end

  def run
    loop do
      work = @coordinator.request_work
      break if work == :shutdown
      next sleep(0.1) if work.nil?

      results = []
      @stage_proc.call(work[:item], ->(r) { results << r })
      results.each { |r| @coordinator.submit_result(r) }
    end
  end
end
```

**Pros:**
- Simple to implement
- Matches existing IPC pattern
- No consensus needed
- Easy to reason about

**Cons:**
- Single point of failure (coordinator)
- All data flows through coordinator (bottleneck)
- No automatic failover

**Complexity: LOW**
**Raft needed: NO**

### Option 2: TupleSpace-Based (Like Linda)

Use Rinda for coordination:

```ruby
# Start TupleSpace server (can be on any node)
ts = Rinda::TupleSpace.new
DRb.start_service('druby://0.0.0.0:9000', ts)

# Producer (on coordinator)
items.each { |item| ts.write(['work', stage_name, item]) }
ts.write(['work', stage_name, :end_of_stage])

# Worker (on any node)
loop do
  _, stage, item = ts.take(['work', stage_name, nil])
  break if item == :end_of_stage

  results = process(item)
  results.each { |r| ts.write(['result', stage, r]) }
end

# Collector (on coordinator)
loop do
  _, stage, result = ts.take(['result', stage_name, nil], timeout)
  break if timeout_expired
  output_queue << result
end
```

**Pros:**
- Clean coordination semantics
- Natural for producer/consumer patterns
- Built into Ruby stdlib

**Cons:**
- Central TupleSpace = single point of failure
- All data flows through TupleSpace
- No persistence

**Complexity: LOW-MEDIUM**
**Raft needed: NO** (but TupleSpace is SPOF)

### Option 3: Gossip-Based Discovery + Direct Communication

Like libcluster's gossip strategy:

```
    ┌─────────┐       ┌─────────┐
    │ Node 1  │◄─────►│ Node 2  │
    │         │       │         │
    └────┬────┘       └────┬────┘
         │                 │
         │    ┌─────────┐  │
         └───►│ Node 3  │◄─┘
              │         │
              └─────────┘
         (gossip heartbeats)
```

**Implementation:**
1. Nodes broadcast UDP heartbeats to multicast address
2. Nodes maintain list of known peers
3. Work distribution happens directly between nodes
4. One node elected as "coordinator" (simple: lowest IP wins)

**Pros:**
- No central server needed
- Automatic discovery
- Direct node-to-node communication

**Cons:**
- More complex implementation
- Need election mechanism for coordinator
- UDP may not work in all network environments
- Still need a "coordinator" concept for work distribution

**Complexity: MEDIUM-HIGH**
**Raft needed: MAYBE** (for robust leader election)

### Option 4: External Coordination Service

Use Redis, etcd, or ZooKeeper for coordination:

```ruby
# Using Redis for work queue
redis = Redis.new(url: ENV['REDIS_URL'])

# Producer
items.each { |item| redis.rpush("work:#{stage}", Marshal.dump(item)) }

# Worker (on any machine)
loop do
  _, data = redis.blpop("work:#{stage}", timeout: 5)
  break unless data

  item = Marshal.load(data)
  results = process(item)
  results.each { |r| redis.rpush("results:#{stage}", Marshal.dump(r)) }
end

# Collector
while result = redis.lpop("results:#{stage}")
  output_queue << Marshal.load(result)
end
```

**Pros:**
- Proven, battle-tested infrastructure
- Built-in persistence
- Pub/sub for events
- Cluster mode for HA (Redis Cluster, etcd, ZK)
- Already handles consensus/election

**Cons:**
- External dependency
- Operational complexity
- Serialization overhead
- Network hop for every operation

**Complexity: MEDIUM** (integration) + **MEDIUM-HIGH** (ops)
**Raft needed: DELEGATED** to Redis Cluster/etcd/ZK

### Option 5: Full Raft Implementation

Build consensus into Minigun using a Ruby Raft library:

```ruby
# Using franckverrot/raft-ruby or harryw/raft
cluster = Raft::Cluster.new(
  nodes: [
    { host: '10.0.0.1', port: 9000 },
    { host: '10.0.0.2', port: 9000 },
    { host: '10.0.0.3', port: 9000 },
  ]
)

# Leader handles work distribution
if cluster.leader?
  cluster.append_log({ type: :work, item: item })
end

# All nodes apply committed entries
cluster.on_commit do |entry|
  process(entry[:item]) if entry[:type] == :work
end
```

**Pros:**
- No external dependencies
- Full control over behavior
- Automatic leader election
- Fault tolerant (N/2+1 nodes survive)

**Cons:**
- Complex to implement correctly
- Ruby Raft libraries are not production-hardened
- Significant testing burden
- Overkill for stateless work distribution

**Complexity: HIGH**
**Raft needed: YES** (that's the whole point)

## Comparison Matrix

| Aspect | Centralized DRb | TupleSpace | Gossip+Direct | External Service | Raft |
|--------|-----------------|------------|---------------|------------------|------|
| **Complexity** | Low | Low-Med | Med-High | Medium | High |
| **SPOF** | Yes | Yes | No* | No | No |
| **Auto-discovery** | No | No | Yes | Depends | No |
| **Fault tolerance** | None | None | Partial | High | High |
| **External deps** | None | None | None | Redis/etcd/ZK | None |
| **Proven in prod** | Limited | Limited | No | Yes | No (Ruby) |
| **Matches IPC pattern** | Yes | Yes | Partially | Yes | No |

\* Gossip still needs a coordinator concept; it's just dynamically elected

## Recommendation

### For Initial Implementation: Option 1 (Centralized DRb) or Option 4 (Redis)

**Reasoning:**

1. **Matches existing patterns**: Our IPC implementation already uses a coordinator pattern
2. **Minimal complexity**: DRb is in stdlib, Redis is ubiquitous
3. **Incremental approach**: Start simple, add complexity as needed
4. **Focus on correctness**: Get the semantics right before optimizing

### Proposed Architecture

```ruby
# DSL Extension
pipeline do
  producer :generate do |output|
    # runs on coordinator
  end

  # Distribute work across cluster
  in_cluster(
    coordinator_uri: 'druby://10.0.0.1:9000',  # or auto-detect
    worker_uris: ['druby://10.0.0.2:9001', 'druby://10.0.0.3:9001'],
    # OR
    redis_uri: 'redis://10.0.0.1:6379',
    # OR
    discovery: :gossip  # future
  ) do
    processor :compute do |item, output|
      # runs on worker nodes
    end
  end

  consumer :collect do |item|
    # runs on coordinator
  end
end
```

### Implementation Phases

#### Phase 1: DRb-Based Coordinator (MVP)
- `ClusterPoolExecutor` using DRb
- Manual worker registration
- Marshal serialization
- No fault tolerance (workers must stay up)

#### Phase 2: Worker Health + Reconnection
- Heartbeat/keepalive mechanism
- Automatic reconnection
- Work requeue on worker failure

#### Phase 3: Optional Redis Backend
- Redis as work queue
- Better persistence
- Easier horizontal scaling

#### Phase 4 (Future): Discovery + HA
- Gossip-based discovery
- Coordinator failover (Raft or external)
- Dynamic scaling

## Key Design Decisions

### 1. Serialization Format

Options:
- **Marshal**: Built-in, Ruby-only, security concerns
- **JSON**: Universal, verbose, no Ruby objects
- **MessagePack**: Fast, compact, limited types
- **BERT**: Erlang-compatible, good for mixed systems

**Recommendation**: Start with Marshal (matches IPC), allow pluggable serializer.

### 2. Work Distribution Strategy

Options:
- **Round-robin**: Simple, may cause hotspots
- **Pull-based**: Workers request work when ready (like IPC)
- **Push with backpressure**: Coordinator tracks worker capacity

**Recommendation**: Pull-based (matches IPC pattern, naturally load-balanced).

### 3. Error Handling

- Worker crashes: Requeue unfinished work
- Network errors: Retry with exponential backoff
- Serialization errors: Log and skip (like IPC)

### 4. Demand/Backpressure

The existing demand system needs adaptation:
- Coordinator tracks global demand
- Workers report local capacity
- Work distribution respects demand limits

## Challenges and Mitigations

### Challenge 1: Code Distribution

**Problem**: Stage blocks (Procs) can't be serialized/sent to remote workers.

**Solutions**:
1. **Workers have code locally**: Same codebase on all machines
2. **DSL for remote stages**: Special syntax that generates serializable task descriptors
3. **Stage registry**: Register stages by name, send name + args remotely

**Recommended approach**: Workers have code locally (simplest, matches deployment models).

### Challenge 2: Network Partitions

**Problem**: Workers may become unreachable.

**Solutions**:
1. **Timeouts**: Assume dead after N seconds of no heartbeat
2. **Work requeue**: Return in-flight work to queue
3. **Idempotent processing**: Design stages to handle reprocessing

### Challenge 3: Coordinator Failure

**Problem**: If coordinator dies, everything stops.

**Solutions (ordered by complexity)**:
1. **Manual restart**: Operator intervention
2. **Standby coordinator**: Passive standby takes over
3. **Consensus-based election**: Full Raft/Paxos

**For MVP**: Accept SPOF, document as limitation.

## Success Criteria

1. **Functional**: `in_cluster` distributes work across network nodes
2. **API consistency**: Similar to `in_ipc_forks` but with remote workers
3. **Performance**: Near-linear scaling with worker count for CPU-bound work
4. **Resilient**: Handles transient network issues gracefully
5. **Observable**: Stats/metrics for cluster health

## References

- [libcluster documentation](https://hexdocs.pm/libcluster/readme.html) - Elixir clustering library
- [DRb (Distributed Ruby)](https://github.com/ruby/drb) - Ruby's built-in distribution
- [Rinda TupleSpace](https://docs.ruby-lang.org/en/3.3/Rinda/TupleSpace.html) - Ruby coordination mechanism
- [harryw/raft](https://github.com/harryw/raft) - Ruby Raft implementation
- [franckverrot/raft-ruby](https://github.com/franckverrot/raft-ruby) - Another Ruby Raft
- [BERT gem](https://github.com/mojombo/bert) - Binary Erlang Term for Ruby
- [Ray overview](https://docs.ray.io/en/latest/ray-overview/index.html) - Python distributed computing
- [Split-brain in distributed systems](https://dzone.com/articles/split-brain-in-distributed-systems) - Partition handling

## Conclusion

**Is clustering realistic in Ruby?** Yes, but with caveats:

1. **Simple clustering (DRb/Rinda)**: Absolutely achievable, matches existing IPC patterns
2. **Production-grade HA**: Requires external coordination (Redis, etcd) or significant Raft implementation effort
3. **Elixir-level transparency**: Not achievable - Ruby lacks VM-level distribution support

**Is Raft needed?**
- For basic work distribution: NO
- For coordinator failover: YES (or delegate to external service)
- For exactly-once semantics: YES

**Recommended path**: Start with DRb-based centralized coordinator, iterate based on real-world feedback.
