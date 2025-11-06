# Fundamentals: Under the Hood

This guide explores the core mechanisms that power Minigun: producer-consumer queues, forking strategies, threading models, and backpressure. Understanding these fundamentals will help you design high-performance pipelines and debug issues effectively.

## Table of Contents

- [Producer-Consumer Queues](#producer-consumer-queues)
- [Threading and the Ruby GVL](#threading-and-the-ruby-gvl)
- [Copy-On-Write (COW) Forking](#copy-on-write-cow-forking)
- [IPC (Inter-Process Communication) Forking](#ipc-inter-process-communication-forking)
- [Ractors: True Parallelism Without Forking](#ractors-true-parallelism-without-forking)
- [Fibers: Cooperative Concurrency](#fibers-cooperative-concurrency)
- [Backpressure Mechanisms](#backpressure-mechanisms)
- [Performance Implications](#performance-implications)

---

## Producer-Consumer Queues

At the heart of every Minigun pipeline is the **producer-consumer queue pattern**. Understanding how these queues work is essential to mastering Minigun.

### What Are Producer-Consumer Queues?

A producer-consumer queue is a thread-safe data structure that allows one thread (the producer) to add items while another thread (the consumer) removes and processes them.

```
┌──────────┐         ┌───────────┐        ┌──────────┐
│ Producer │──push──>│   Queue   │──pop──>│ Consumer │
│  Thread  │         │ (bounded) │        │  Thread  │
└──────────┘         └───────────┘        └──────────┘
```

**Key Properties:**
- **Thread-safe**: Multiple threads can safely access the queue
- **FIFO ordering**: First In, First Out (usually)
- **Bounded size**: Limited capacity prevents memory exhaustion
- **Blocking operations**: Push blocks when full, pop blocks when empty

### Implementation: Ruby's SizedQueue

Minigun uses Ruby's `SizedQueue` class from the standard library:

```ruby
require 'thread'

# Create a queue with max size of 10 items
queue = SizedQueue.new(10)

# Producer thread
producer = Thread.new do
  100.times do |i|
    queue << i  # Blocks if queue is full
    puts "Produced: #{i}"
  end
  queue << :END_OF_DATA  # Sentinel value
end

# Consumer thread
consumer = Thread.new do
  loop do
    item = queue.pop  # Blocks if queue is empty
    break if item == :END_OF_DATA
    puts "Consumed: #{item}"
    sleep 0.01  # Simulate work
  end
end

producer.join
consumer.join
```

**What Happens:**
1. Producer generates items faster than consumer processes them
2. Queue fills up to capacity (10 items)
3. Producer **blocks** on `queue <<` until consumer makes space
4. Consumer processes items, making room in the queue
5. Producer **unblocks** and continues

This is **automatic backpressure** in action!

### How Minigun Uses Queues

Every connection between stages in a pipeline is a queue:

```ruby
pipeline do
  producer :generate do |output|
    output << "data"  # Pushes to Queue 1
  end

  processor :transform do |item, output|
    output << item.upcase  # Pops from Queue 1, pushes to Queue 2
  end

  consumer :print do |item|
    puts item  # Pops from Queue 2
  end
end
```

**Execution Model:**

```
Producer Thread ──> Queue 1 ──> Processor Thread ──> Queue 2 ──> Consumer Thread
```

Each stage runs in its own thread (or process), connected by queues.

### Queue Configuration

You can configure queue sizes per stage:

```ruby
processor :transform, queue_size: 1000 do |item, output|
  output << expensive_operation(item)
end
```

**Trade-offs:**

| Queue Size | Pros | Cons |
|-----------|------|------|
| Small (10-100) | Low memory usage, fast backpressure | More blocking, potential throughput loss |
| Medium (500) | Good balance (default) | Moderate memory usage |
| Large (5000+) | High throughput, absorbs bursts | High memory usage, delayed backpressure |

**Rule of Thumb:**
- **Fast stages**: Small queues (less buffering needed)
- **Slow stages**: Larger queues (absorb input bursts)
- **Memory-constrained**: Smaller queues everywhere

### End-of-Stage Signaling

When a producer finishes, how do downstream stages know? Minigun uses special **sentinel objects**:

```ruby
class EndOfStage; end

# Producer signals completion
queue << EndOfStage.new

# Consumer detects end
loop do
  item = queue.pop
  break if item.is_a?(EndOfStage)
  process(item)
end
```

This propagates through the entire pipeline, allowing graceful shutdown.

---

## Threading and the Ruby GVL

Understanding Ruby's threading model is crucial for performance tuning.

### The Global VM Lock (GVL)

Ruby MRI has a **Global VM Lock** (also called GIL - Global Interpreter Lock):

```
┌───────────────────────────────────┐
│          Ruby Process             │
│                                   │
│  ┌──────────┐  ┌──────────┐       │
│  │ Thread 1 │  │ Thread 2 │       │
│  └────┬─────┘  └────┬─────┘       │
│       │             │             │
│       └──────┬──────┘             │
│              │                    │
│         ┌────▼────┐               │
│         │   GVL   │ <- Only one   │
│         │  Lock   │    thread at  │
│         └─────────┘    a time!    │
│                                   │
└───────────────────────────────────┘
```

**What This Means:**
- Only **one thread** can execute Ruby code at a time
- CPU-bound work in threads **doesn't parallelize**
- I/O-bound work **does parallelize** (GVL released during I/O)

### When Threading Works Well

Threads are excellent for **I/O-bound** operations:

```ruby
# Network requests - threads work great!
processor :fetch, threads: 20 do |url, output|
  response = HTTP.get(url)  # GVL released during network I/O
  output << response.body
end

# Database queries - threads work great!
processor :query, threads: 10 do |id, output|
  record = Database.find(id)  # GVL released during I/O
  output << record
end
```

**Why It Works:**
- Thread makes network/DB request
- Ruby **releases the GVL** during I/O wait
- Another thread can run Ruby code
- When I/O completes, thread reacquires GVL

**Performance:** 20 threads can handle 20 concurrent HTTP requests!

### When Threading Doesn't Work

Threads are **poor** for **CPU-bound** operations:

```ruby
# CPU-intensive work - threads DON'T parallelize!
processor :calculate, threads: 20 do |data, output|
  result = expensive_cpu_calculation(data)  # GVL held entire time
  output << result
end
```

**Why It Doesn't Work:**
- Thread holds GVL during CPU work
- No I/O to release the GVL
- Other threads **wait** for GVL
- Effectively **sequential execution**

**Performance:** 20 threads behave like 1 thread!

### Thread Pool Sizing

For I/O-bound work, how many threads should you use?

**Formula:**
```
threads = (desired_concurrency × avg_wait_time) / avg_processing_time
```

**Example:**
- HTTP request avg latency: 100ms
- Processing time: 10ms
- Desired concurrency: 50 requests

```
threads = (50 × 100ms) / 10ms = 50 threads
```

**Practical Limits:**
- Start with **2× your desired concurrency**
- Monitor with HUD to see if threads are idle or busy
- Increase until throughput plateaus

---

## Copy-On-Write (COW) Forking

For CPU-bound work, **forking** achieves true parallelism by using multiple processes.

### What Is COW Forking?

**Copy-On-Write** is a memory optimization where forked processes share memory until they modify it:

```
Before Fork:
┌─────────────────┐
│ Parent Process  │
│                 │
│ Memory: 500MB   │
└─────────────────┘

After Fork (COW):
┌─────────────────┐      ┌─────────────────┐
│ Parent Process  │      │ Child Process   │
│                 │      │                 │
│ Memory: 500MB   │◄────►│ Memory: 500MB   │
│                 │      │ (shared!)       │
└─────────────────┘      └─────────────────┘

After Child Writes:
┌─────────────────┐      ┌─────────────────┐
│ Parent Process  │      │ Child Process   │
│                 │      │                 │
│ Memory: 500MB   │      │ Memory: 510MB   │
│                 │      │ (10MB copied)   │
└─────────────────┘      └─────────────────┘
```

**Key Insight:** If child processes **only read** shared data, they use almost no extra memory!

### How Minigun Uses COW Forks

```ruby
# Load large dataset BEFORE forking
REFERENCE_DATA = load_huge_database  # 500MB

class Pipeline
  include Minigun::DSL

  pipeline do
    producer :generate do |output|
      1000.times { |i| output << i }
    end

    # Fork 8 workers - they all share REFERENCE_DATA!
    processor :lookup, cow_forks: 8 do |id, output|
      # Only reading from REFERENCE_DATA - no memory copy!
      result = REFERENCE_DATA[id]
      output << result
    end

    consumer :save do |result|
      Database.save(result)
    end
  end
end
```

**Memory Usage:**
- **Without COW**: 500MB × 8 processes = 4GB
- **With COW**: 500MB + (8 × small overhead) ≈ 550MB

**Huge savings!**

### When to Use COW Forks

**Ideal For:**
- CPU-intensive work (image processing, parsing, computation)
- Large shared read-only data (ML models, reference tables, configs)
- Short-lived tasks (process starts, runs, exits quickly)

**Example Use Cases:**
- Image resizing with a shared font library
- Log parsing with shared regex patterns
- Data enrichment with a shared lookup table

**Code Pattern:**

```ruby
# Load shared data at top level (before fork)
LOOKUP_TABLE = YAML.load_file('huge_table.yml')  # 200MB
ML_MODEL = TensorFlow.load_model('model.pb')     # 1GB

class Pipeline
  include Minigun::DSL

  pipeline do
    producer :load_images do |output|
      Dir.glob('*.jpg').each { |f| output << f }
    end

    # Workers share LOOKUP_TABLE and ML_MODEL!
    processor :process, cow_forks: 4 do |image_path, output|
      image = load_image(image_path)
      prediction = ML_MODEL.predict(image)  # Read-only access
      enriched = LOOKUP_TABLE[prediction]   # Read-only access
      output << enriched
    end

    consumer :save do |result|
      File.write("result.json", result.to_json)
    end
  end
end
```

### COW Fork Lifecycle

```
1. Parent loads shared data (500MB)
2. Parent forks 8 workers
3. Workers inherit shared memory (COW)
4. Workers process items (read-only)
5. Workers finish and exit
6. Parent continues
```

**Key Points:**
- Workers **exit after processing** (fork_and_process model)
- Each item spawns a new fork (fresh memory each time)
- Good for short tasks, expensive for long tasks

### Limitations

**When NOT to Use COW Forks:**

1. **Workers modify large data structures**
   ```ruby
   # BAD: Modifying shared data triggers full copy!
   processor :modify, cow_forks: 8 do |item, output|
     SHARED_DATA[item] = compute(item)  # Triggers COW!
   end
   ```

2. **Long-running tasks**
   ```ruby
   # BAD: Fork overhead repeated for each item
   processor :slow, cow_forks: 8 do |item, output|
     sleep 10  # New fork every 10 seconds - wasteful!
   end
   ```
   Use IPC forks instead (see below).

3. **Platform limitations**
   - Windows: No fork support
   - JRuby/TruffleRuby: Limited fork support

---

## IPC (Inter-Process Communication) Forking

When you need persistent worker processes, use **IPC forking**.

### What Is IPC Forking?

IPC creates a **pool of persistent workers** that communicate via pipes:

```
         ┌─────────────┐
         │   Parent    │
         │   Process   │
         └──────┬──────┘
                │
   ┌────────┬───┴────┬────────┐
   │        │        │        │
┌──▼───┐ ┌──▼───┐ ┌──▼───┐ ┌──▼───┐
│Worker│ │Worker│ │Worker│ │Worker│
│  1   │ │  2   │ │  3   │ │  4   │
└──────┘ └──────┘ └──────┘ └──────┘
  (pipe)  (pipe)  (pipe)   (pipe)
```

**Key Differences from COW:**
- Workers **persist** across many items
- Communication via **serialized messages** (Marshal or JSON)
- No shared memory (each worker has its own copy)

### How Minigun Uses IPC Forks

```ruby
pipeline do
  producer :generate do |output|
    10_000.times { |i| output << i }
  end

  # Create 4 persistent workers
  processor :compute, ipc_forks: 4 do |number, output|
    result = expensive_computation(number)
    output << result
  end

  consumer :save do |result|
    Database.save(result)
  end
end
```

**Lifecycle:**

```
1. Parent spawns 4 worker processes
2. Workers load, initialize, wait for work
3. Parent sends item #1 to Worker 1 (via pipe)
4. Parent sends item #2 to Worker 2 (via pipe)
5. Parent sends item #3 to Worker 3 (via pipe)
6. Parent sends item #4 to Worker 4 (via pipe)
7. Parent sends item #5 to Worker 1 (round-robin)
...
10,000. Workers finish, parent signals shutdown
11. Workers exit gracefully
```

**Key Insight:** Workers are reused! No fork overhead per item.

### Serialization Overhead

IPC requires serializing data between processes:

```ruby
# Parent side
item = { id: 123, data: "..." }
serialized = Marshal.dump(item)  # Convert to bytes
pipe.write(serialized)            # Send to worker

# Worker side
serialized = pipe.read            # Receive bytes
item = Marshal.load(serialized)   # Convert back to Ruby object
process(item)
```

**Performance Impact:**
- Small objects (< 1KB): Negligible overhead
- Medium objects (1-100KB): Small overhead
- Large objects (> 1MB): Significant overhead

**Optimization Tips:**

```ruby
# BAD: Sending huge objects
processor :process, ipc_forks: 4 do |huge_object, output|
  # huge_object is serialized/deserialized - slow!
end

# GOOD: Send small identifiers, load data in worker
processor :process, ipc_forks: 4 do |id, output|
  # Worker loads its own copy of large data
  data = WORKER_LOCAL_CACHE[id]
  process(data)
end
```

### When to Use IPC Forks

**Ideal For:**
- CPU-intensive work with **long initialization time**
- Workers that need to maintain **persistent state**
- Processing many small items efficiently

**Example Use Cases:**

1. **ML Model Inference:**
   ```ruby
   # Load model once per worker (expensive!)
   processor :predict, ipc_forks: 4, init: ->(worker) {
     worker.model = load_ml_model  # 2 seconds to load
   } do |image_data, output|
     prediction = @model.predict(image_data)  # 50ms per prediction
     output << prediction
   end
   ```

2. **Database Connection Pools:**
   ```ruby
   processor :query, ipc_forks: 8, init: ->(worker) {
     worker.db = Database.connect  # Persistent connection
   } do |query, output|
     result = @db.execute(query)
     output << result
   end
   ```

3. **Stateful Processing:**
   ```ruby
   processor :aggregate, ipc_forks: 1, init: ->(worker) {
     worker.accumulator = Hash.new(0)
   } do |event, output|
     @accumulator[event.type] += 1
     output << @accumulator if @accumulator.values.sum % 1000 == 0
   end
   ```

### IPC vs COW Comparison

| Aspect | COW Forks | IPC Forks |
|--------|-----------|-----------|
| **Worker lifetime** | One item, then exit | Persistent pool |
| **Fork overhead** | High (every item) | Low (once at start) |
| **Memory sharing** | Yes (read-only) | No (separate memory) |
| **Serialization** | None | Required |
| **Initialization** | Every item | Once per worker |
| **Best for** | Short tasks, shared data | Long tasks, persistent state |

**Decision Tree:**

```
Does the task have expensive setup (e.g., loading ML model)?
├─ Yes → Use IPC forks
└─ No
    └─ Do you have large shared read-only data?
        ├─ Yes → Use COW forks
        └─ No → Use threads (if I/O-bound) or IPC forks (if CPU-bound)
```

---

## Ractors: Parallelism Without Forking

Ruby 3.0 introduced **Ractors** (Ruby Actors) - a new concurrency primitive that achieves true parallelism without the GVL limitation.

### What Are Ractors?

Ractors are isolated execution units that run in parallel without sharing most objects:

```
┌────────────────────────────────┐
│          Ruby Process          │
│                                │
│  ┌──────────┐    ┌──────────┐  │
│  │ Ractor 1 │    │ Ractor 2 │  │
│  │  Own     │    │  Own     │  │
│  │  Memory  │    │  Memory  │  │
│  └────┬─────┘    └────┬─────┘  │
│       │               │        │
│       └───────┬───────┘        │
│               │                │
│       ┌───────▼────────┐       │
│       │  Message Pass  │       │
│       │  (Copy/Move)   │       │
│       └────────────────┘       │
│                                │
│  NO GVL CONTENTION!            │
└────────────────────────────────┘
```

**Key Properties:**
- **True parallelism**: Multiple Ractors run simultaneously on different CPU cores.
- **Isolated memory**: Each Ractor has its own object space. Unlike COW forking, where memory is shared, N ractors means ~N times the memory usage!
- **Message passing**: Communication via message ports (analogous to IPC sockets.)
- **No GVL sharing**: Each Ractor has its own GVL, meaning that one Ractor does not lock the execution of another.

### How Ractors Work

Basic ractor example:

```ruby
# Create a ractor that processes numbers
ractor = Ractor.new do
  loop do
    # Receive a number
    n = Ractor.receive
    break if n == :stop

    # Process it (CPU-intensive)
    result = expensive_computation(n)

    # Send result back
    Ractor.yield(result)
  end
end

# Main ractor sends work
ractor.send(42)
result = ractor.take  # Blocks until result is ready
puts result

# Cleanup
ractor.send(:stop)
```

**Message Passing Rules:**

1. **Immutable objects** are shared (symbols, numbers, true, false, nil):
   ```ruby
   ractor.send(:symbol)  # No copy needed
   ractor.send(123)       # No copy needed
   ```

2. **Mutable objects** are deep copied by default:
   ```ruby
   ractor.send([1, 2, 3])  # Array is deep copied
   ractor.send({a: 1})     # Hash is deep copied
   ```

3. **Move semantics** for zero-copy transfer:
   ```ruby
   ractor.send(large_data, move: true)  # Ownership transferred
   # large_data is now inaccessible in current ractor!
   ```

### Minigun and Ractors

**Current Status:** Minigun does not currently use ractors directly, but they could be integrated in the future.

**Why Not Ractors (Yet)?**

1. **Complexity of isolation**: Most Ruby objects aren't ractor-safe
2. **Message passing overhead**: Deep copying large objects is expensive
3. **Ecosystem maturity**: Many gems aren't ractor-compatible yet
4. **Platform support**: Ractors are still experimental and evolving

**Potential Future Use Cases:**

```ruby
# Hypothetical ractor-based execution strategy
processor :compute, ractors: 8 do |item, output|
  # Runs in isolated ractor
  result = cpu_intensive_work(item)
  output << result
end
```

**Benefits over threads:**
- True CPU parallelism (no GVL)
- Better for CPU-bound work than threads

**Benefits over forks:**
- Lower memory overhead than IPC forks
- Faster than COW fork creation
- Better process management

### Ractors vs Other Strategies

| Aspect | Threads | Ractors | COW Forks | IPC Forks |
|--------|---------|---------|-----------|-----------|
| **True parallelism** | No (GVL) | Yes | Yes | Yes |
| **Memory isolation** | No (shared) | Yes | Yes | Yes |
| **Startup overhead** | Very low | Low | Medium | Medium |
| **Communication** | Shared memory | Message passing | Queues | Pipes (serialization) |
| **Shared data** | Direct access | Copy/move only | COW read-only | None (separate) |
| **Ecosystem support** | Excellent | Limited | Excellent | Excellent |
| **Platform support** | All platforms | MRI 3.0+ | Unix-like only | Unix-like only |

### When Ractors Might Be Useful

**Future scenarios where ractors could excel:**

1. **CPU-bound work with small data**
   ```ruby
   # Efficient: small inputs/outputs
   processor :hash_password, ractors: 8 do |password, output|
     output << BCrypt.hash(password)  # CPU-intensive, small data
   end
   ```

2. **Pure computational pipelines**
   ```ruby
   # No shared state, pure functions
   processor :calculate, ractors: 8 do |numbers, output|
     output << numbers.map { |n| Math.sqrt(n) }.sum
   end
   ```

3. **Stateless transformations**
   ```ruby
   # Each item processed independently
   processor :transform, ractors: 16 do |item, output|
     output << transform_pure_function(item)
   end
   ```

**Not ideal for:**
- Large shared read-only data (COW forks are better)
- Complex object graphs (deep copy overhead)
- Code relying on non-ractor-safe gems

---

## Fibers: Cooperative Concurrency

**Fibers** are lightweight concurrency primitives for cooperative multitasking within a single thread.

### What Are Fibers?

Fibers are like threads, but **manually scheduled**:

```
┌─────────────────────────────────────┐
│          Ruby Thread                │
│                                     │
│  ┌──────────┐    ┌──────────┐     │
│  │ Fiber 1  │    │ Fiber 2  │     │
│  │          │    │          │     │
│  └────┬─────┘    └────┬─────┘     │
│       │               │            │
│       └───────┬───────┘            │
│               │                    │
│       ┌───────▼────────┐           │
│       │  Manual Switch │           │
│       │  (Fiber.yield) │           │
│       └────────────────┘           │
│                                     │
│  Single-threaded!                  │
└─────────────────────────────────────┘
```

**Key Properties:**
- **Cooperative**: Fibers explicitly yield control
- **Lightweight**: Much lower overhead than threads
- **Synchronous**: Only one fiber runs at a time (no parallelism)
- **Stack-based**: Each fiber has its own stack

### How Fibers Work

Basic fiber example:

```ruby
fiber1 = Fiber.new do
  puts "Fiber 1: Starting"
  Fiber.yield  # Give control back
  puts "Fiber 1: Resuming"
  Fiber.yield
  puts "Fiber 1: Done"
end

fiber2 = Fiber.new do
  puts "Fiber 2: Starting"
  Fiber.yield
  puts "Fiber 2: Done"
end

# Manual scheduling
fiber1.resume  # Fiber 1: Starting
fiber2.resume  # Fiber 2: Starting
fiber1.resume  # Fiber 1: Resuming
fiber1.resume  # Fiber 1: Done
fiber2.resume  # Fiber 2: Done
```

**Execution:**
```
Main thread
  ↓
Fiber 1: Starting
  ↓ (yield)
Fiber 2: Starting
  ↓ (yield)
Fiber 1: Resuming
  ↓ (yield)
Fiber 1: Done
  ↓
Fiber 2: Done
```

### Async Fibers (Ruby 3.0+)

Ruby 3.0 introduced **async fibers** with automatic scheduling:

```ruby
require 'async'

Async do
  # Create async tasks (fibers)
  task1 = Async do
    sleep 1
    puts "Task 1 done"
    42
  end

  task2 = Async do
    sleep 0.5
    puts "Task 2 done"
    100
  end

  # Wait for results
  results = [task1.wait, task2.wait]
  puts "Results: #{results}"
end
# Output:
# Task 2 done
# Task 1 done
# Results: [42, 100]
```

**Key Difference:** Async library provides an event loop that automatically switches fibers during I/O operations.

### Minigun and Fibers

**Current Status:** Minigun uses threads and processes, not fibers.

**Why Not Fibers?**

1. **No true parallelism**: Fibers are cooperative, not parallel
2. **Manual scheduling**: Requires explicit yielding (or async library)
3. **Limited ecosystem**: Most libraries are thread-based, not fiber-aware
4. **Complexity**: Harder to reason about than threads

**Potential Use Cases:**

Fibers *could* be useful for:

1. **High-concurrency I/O with low memory**
   ```ruby
   # Hypothetical fiber-based execution
   processor :fetch, fibers: 10_000 do |url, output|
     response = Async::HTTP.get(url)  # Yields during I/O
     output << response.body
   end
   ```
   - 10,000 fibers use much less memory than 10,000 threads
   - Good for high-concurrency I/O workloads

2. **Generator-style pipelines**
   ```ruby
   # Lazy generation with fibers
   producer :generate do |output|
     fiber = Fiber.new do
       loop do
         Fiber.yield compute_next_value
       end
     end

     10.times { output << fiber.resume }
   end
   ```

**Limitations:**
- No CPU parallelism (single-threaded)
- Requires fiber-aware I/O libraries (e.g., async gem)
- More complex than threads

### Fibers vs Threads

| Aspect | Threads | Fibers |
|--------|---------|--------|
| **Scheduling** | Preemptive (automatic) | Cooperative (manual) |
| **Parallelism** | Yes (with I/O) | No (single-threaded) |
| **Memory per unit** | ~1MB stack | ~4KB stack |
| **Concurrency limit** | 100s-1000s | 10,000s-100,000s |
| **Switching overhead** | High (kernel) | Low (userspace) |
| **Ease of use** | Easy | Harder (manual control) |
| **GVL contention** | Yes | No (single-threaded) |

**Decision Guide:**

```
Need true parallelism?
├─ Yes → Use threads (I/O) or forks (CPU)
└─ No
    └─ Need high concurrency (10K+ connections)?
        ├─ Yes → Consider fibers with async I/O
        └─ No → Use threads (simpler)
```

### Fibers in Practice

**Where fibers excel:**

```ruby
# Web server handling 10K concurrent connections
# (Using async gem with fibers)
require 'async'
require 'async/http/server'

Async do |task|
  # Each connection handled by a fiber
  server = Async::HTTP::Server.new do |request|
    # Fiber yields during I/O
    response = fetch_data(request.path)
    Protocol::HTTP::Response[200, {}, [response]]
  end

  endpoint = Async::HTTP::Endpoint.parse('http://localhost:3000')
  server.run(endpoint)
end
```

**Why this works:**
- 10,000 fibers use ~40MB (vs ~10GB for threads)
- Async I/O yields fibers during network wait
- Event loop efficiently schedules fiber switching

**Why Minigun doesn't use this:**
- Most data pipeline work is batch processing, not real-time serving
- Threads provide good enough concurrency for typical use cases
- Simpler mental model (preemptive scheduling)

---

## Backpressure Mechanisms

Backpressure prevents fast producers from overwhelming slow consumers.

### The Problem: Unbounded Queues

Without backpressure:

```ruby
# Dangerous: Unbounded queue
queue = Queue.new  # No size limit!

producer = Thread.new do
  1_000_000.times { |i| queue << i }  # Never blocks!
end

consumer = Thread.new do
  loop do
    item = queue.pop
    sleep 0.01  # Slow consumer
    process(item)
  end
end
```

**What Happens:**
1. Producer generates 1M items in < 1 second
2. Consumer processes at 100 items/second
3. Queue grows to 1M items → **memory exhaustion!**

### The Solution: Bounded Queues

Minigun uses bounded queues (SizedQueue):

```ruby
queue = SizedQueue.new(100)  # Max 100 items

producer = Thread.new do
  1_000_000.times do |i|
    queue << i  # Blocks when queue is full!
  end
end

consumer = Thread.new do
  loop do
    item = queue.pop
    sleep 0.01
    process(item)
  end
end
```

**What Happens:**
1. Producer fills queue to 100 items
2. Producer **blocks** on `queue << item`
3. Consumer processes 1 item, queue has 99 items
4. Producer **unblocks**, adds 1 item
5. Queue stays at ~100 items → **memory stays constant!**

### Visualizing Backpressure

```
Time: 0s
Producer: ████████████████████ (generating fast)
Queue:    [■■■■■■■■■■] (full - 100 items)
Consumer: █ (processing slow)

Producer blocks! ⏸️

Time: 1s
Producer: (blocked, waiting...)
Queue:    [■■■■■■■■■■] (still full)
Consumer: ██ (processed 10 items)

Queue has space!

Time: 2s
Producer: █████ (resumed, adding 10 items)
Queue:    [■■■■■■■■■■] (full again)
Consumer: ██ (processed 10 more)
```

### Tuning Backpressure

Queue size affects behavior:

**Small Queue (10 items):**
```ruby
processor :slow, queue_size: 10 do |item, output|
  sleep 0.1
  output << process(item)
end
```
- **Aggressive backpressure** - Producer blocks quickly
- **Low memory usage**
- **Risk:** May underutilize fast producers

**Large Queue (5000 items):**
```ruby
processor :slow, queue_size: 5000 do |item, output|
  sleep 0.1
  output << process(item)
end
```
- **Delayed backpressure** - Producer rarely blocks
- **High memory usage**
- **Benefit:** Absorbs traffic bursts

**Finding the Right Size:**

1. **Monitor with HUD** - Look for idle stages
2. **Measure memory** - Ensure it's acceptable
3. **Test with bursts** - Simulate production traffic

**Rule of Thumb:**
```
queue_size ≈ (burst_size / num_workers) × safety_margin
```

Example:
- Burst size: 1000 items
- Workers: 10
- Safety margin: 2×

```
queue_size = (1000 / 10) × 2 = 200
```

### Multi-Stage Backpressure

Backpressure propagates through the entire pipeline:

```
Producer ──> Queue 1 ──> Stage A ──> Queue 2 ──> Stage B ──> Queue 3 ──> Consumer
(fast)       [full!]                 [full!]                 [full!]     (slow)

All queues full → Producer blocked!
```

**Example:**

```ruby
pipeline do
  producer :generate do |output|
    # Generates 10K items/sec
    infinite_stream.each { |item| output << item }
  end

  processor :step1, queue_size: 100 do |item, output|
    output << process_step1(item)  # 5K items/sec
  end

  processor :step2, queue_size: 100 do |item, output|
    output << process_step2(item)  # 5K items/sec
  end

  consumer :save do |item|
    Database.save(item)  # 1K items/sec (bottleneck!)
  end
end
```

**Execution:**
1. Producer generates at 10K items/sec
2. Queue 1 fills up (step1 can only process 5K/sec)
3. Producer slows to 5K items/sec (backpressure from Queue 1)
4. Queue 2 fills up (step2 outputs 5K/sec, consumer only handles 1K/sec)
5. Step1 slows to 1K items/sec (backpressure from Queue 2)
6. Producer slows to 1K items/sec (backpressure from Queue 1)

**Result:** Entire pipeline runs at the speed of the **slowest stage** (1K items/sec).

This is **automatic rate limiting** - no code required!

---

## Performance Implications

Understanding these fundamentals helps you make informed performance decisions.

### Execution Strategy Selection

| Workload | Strategy | Why |
|----------|----------|-----|
| HTTP API calls | Threads (20-50) | I/O-bound, GVL released during network wait |
| Database queries | Threads (10-20) | I/O-bound, GVL released during query |
| JSON parsing | Threads (4-8) | Mixed I/O/CPU, some GVL contention |
| Image resizing | COW forks (4-8) | CPU-bound, shared font/color data |
| ML inference (fast) | COW forks (4-8) | CPU-bound, model loaded at top level |
| ML inference (slow) | IPC forks (4-8) | CPU-bound, avoid reload per item |
| Log parsing | COW forks (8-16) | CPU-bound, shared regex patterns |
| Video encoding | IPC forks (4-8) | CPU-bound, long tasks |

### Memory Optimization

**Minimize Memory per Process:**

```ruby
# BAD: Loading inside fork (each worker has full copy)
processor :process, cow_forks: 8 do |item, output|
  data = load_huge_dataset  # 500MB × 8 = 4GB!
  result = process(item, data)
  output << result
end

# GOOD: Load before fork (COW shares memory)
SHARED_DATA = load_huge_dataset  # 500MB × 1 = 500MB!

processor :process, cow_forks: 8 do |item, output|
  result = process(item, SHARED_DATA)  # Read-only access
  output << result
end
```

**Trade Memory for Throughput:**

```ruby
# Low memory, low throughput
processor :transform, queue_size: 10, threads: 2 do |item, output|
  output << transform(item)
end

# Higher memory, higher throughput
processor :transform, queue_size: 500, threads: 20 do |item, output|
  output << transform(item)
end
```

### CPU Core Requirements

**Thread Pools:**
- Threads share CPU cores
- More threads than cores is fine (I/O wait time)

**Fork Pools:**
- Each process needs a CPU core for true parallelism
- Formula: `max_forks ≤ CPU cores - 1` (leave one for parent)

**Example:**

```ruby
# System: 8 CPU cores

# BAD: Over-subscription (16 forks, 8 cores)
processor :compute, cow_forks: 16 do |item, output|
  output << cpu_intensive_work(item)
end
# Result: Context switching overhead, no performance gain

# GOOD: Match core count (7 forks, 8 cores)
processor :compute, cow_forks: 7 do |item, output|
  output << cpu_intensive_work(item)
end
# Result: 7× speedup, one core left for parent
```

### Latency vs Throughput

**Low Latency (process items quickly):**

```ruby
# Small queues, fewer workers
processor :fast, queue_size: 10, threads: 4 do |item, output|
  output << item
end
```
- Items spend less time waiting in queues
- Lower overall memory usage
- May sacrifice throughput

**High Throughput (process many items):**

```ruby
# Large queues, many workers
processor :fast, queue_size: 1000, threads: 20 do |item, output|
  output << item
end
```
- Items may wait longer in queues
- Higher memory usage
- Maximizes items processed per second

---

## Key Takeaways

1. **Producer-Consumer Queues:**
   - Foundation of Minigun's architecture
   - Provide decoupling, buffering, and automatic backpressure
   - Implemented with Ruby's `SizedQueue` for thread safety

2. **Threading and the GVL:**
   - Excellent for I/O-bound work (GVL released during I/O)
   - Poor for CPU-bound work (GVL prevents true parallelism)
   - Size thread pools based on desired concurrency × wait time

3. **COW Forking:**
   - Achieves true parallelism for CPU-bound work
   - Shares read-only memory between processes (huge memory savings)
   - Best for short tasks with large shared data

4. **IPC Forking:**
   - Persistent worker processes for long-running tasks
   - Communication via serialized messages (overhead)
   - Best for tasks with expensive initialization

5. **Backpressure:**
   - Bounded queues prevent memory exhaustion
   - Automatically slows fast producers to match slow consumers
   - Entire pipeline runs at the speed of the slowest stage

6. **Performance Implications:**
   - Match execution strategy to workload characteristics
   - Balance memory usage vs throughput
   - Don't over-subscribe CPU cores with forks

---

## Next Steps

Now that you understand the fundamentals, you can:

- **Optimize Existing Pipelines:** Apply these concepts to tune performance
- **Debug Issues:** Understand why stages block or memory grows
- **Design New Pipelines:** Choose the right execution strategies upfront

→ [**Performance Tuning Guide**](11_performance_tuning.md) - Apply these fundamentals to optimize your pipelines

→ [**Testing Guide**](12_testing.md) - Test pipelines with different execution strategies

---

**See Also:**
- [Configuration Guide](15_configuration.md) - Configure queue sizes, thread pools, and fork pools
- [Error Handling Guide](14_error_handling.md) - Handle errors in multi-process pipelines
- [HUD Guide](10_hud.md) - Monitor queue depths and throughput in real-time
