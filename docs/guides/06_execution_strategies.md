# Execution Strategies

Minigun supports four execution strategies for running stages. Each strategy has different characteristics and use cases. Let's explore when and how to use each one.

## The Four Strategies

| Strategy | Concurrency | Process Model | Memory | Best For |
|----------|-------------|---------------|--------|----------|
| **Inline** | None | Single-threaded | Shared | Debugging |
| **Thread** | Threads | Single process | Shared | I/O-bound work |
| **COW Fork** | Processes | Fork per item | Copy-on-write | CPU + large data |
| **IPC Fork** | Processes | Persistent workers | Isolated | CPU + long-running |

## 1. Inline Execution

**Single-threaded, sequential execution**

```ruby
class SimpleTask
  include Minigun::DSL

  execution :inline  # No concurrency

  pipeline do
    producer :generate do |output|
      10.times { |i| output << i }
    end

    processor :transform do |n, output|
      output << n * 2
    end

    consumer :print do |n|
      puts n
    end
  end
end
```

### When to Use Inline

✅ **Good for:**
- **Debugging** - Easy to step through with a debugger
- **Testing** - Predictable, deterministic execution
- **Simple pipelines** - Fast operations that don't need parallelism
- **Development** - Easier to understand what's happening

❌ **Avoid for:**
- Production workloads
- Slow operations
- Large datasets

## 2. Thread Pool Execution (Default)

**Concurrent threads within a single process**

```ruby
class ThreadedTask
  include Minigun::DSL

  execution :thread, max: 10  # Up to 10 threads

  pipeline do
    producer :urls do |output|
      100.times { |i| output << "https://example.com/page#{i}" }
    end

    processor :fetch, threads: 20 do |url, output|
      # 20 threads fetching concurrently
      response = HTTP.get(url)
      output << response.body
    end

    consumer :save, threads: 5 do |content|
      save_to_database(content)
    end
  end
end
```

### Characteristics

- **Shared memory** - All threads access the same objects
- **Ruby GVL** - Subject to Global VM Lock (limits CPU parallelism)
- **Lightweight** - Low overhead for creating threads
- **Fast communication** - No serialization between stages

### When to Use Threads

✅ **Perfect for:**
- **I/O-bound operations** (network, disk, database)
- **When you need shared memory**
- **Moderate concurrency** (10-50 threads)
- **Fast operations** with waiting

❌ **Avoid for:**
- CPU-intensive computations (GVL limits parallelism)
- When isolation is critical

### Example: API Client

```ruby
class APIFetcher
  include Minigun::DSL

  execution :thread, max: 50

  pipeline do
    producer :generate_urls do |output|
      (1..1000).each { |id| output << id }
    end

    processor :fetch, threads: 50 do |id, output|
      # 50 concurrent API requests
      data = HTTP.get("https://api.example.com/users/#{id}")
      output << JSON.parse(data.body)
    end

    consumer :save, threads: 10 do |user|
      database.insert(user)
    end
  end
end
```

## 3. COW Fork Execution

**Fork a new process for EACH item**

```ruby
class COWTask
  include Minigun::DSL

  execution :cow_fork, max: 4  # Up to 4 concurrent processes

  pipeline do
    producer :generate do |output|
      100.times { |i| output << i }
    end

    processor :heavy_compute do |item, output|
      # Each item processed in its own forked process
      result = expensive_computation(item)
      output << result
    end

    consumer :save do |result|
      save_result(result)
    end
  end
end
```

### How COW Fork Works

1. Parent process pulls item from queue
2. **Forks a new child process** (uses copy-on-write)
3. Child processes the item
4. Child writes result to output queue
5. **Child exits immediately**
6. Parent waits for child and repeats

### Characteristics

- **Fork per item** - Each item gets a fresh process
- **Copy-on-write memory** - Parent's memory shared until modified
- **No GVL limitation** - True parallelism
- **Auto-cleanup** - Memory freed when process exits
- **No serialization** - Inherits parent's memory state

### When to Use COW Fork

✅ **Perfect for:**
- **CPU-intensive work** with large read-only data
- **Memory-leaking operations** (auto-cleanup on exit)
- **Isolation** - Each item in separate process
- **Large shared datasets** (lookup tables, models, configs)

❌ **Avoid for:**
- Fast operations (fork overhead)
- Many small items
- When you need persistent state

### Example: Image Processing

```ruby
class ImageProcessor
  include Minigun::DSL

  def initialize
    # Large ML model loaded in parent (50MB)
    @model = MLModel.load('image_classifier.model')
  end

  execution :cow_fork, max: 8

  pipeline do
    producer :images do |output|
      Dir['images/*.jpg'].each { |path| output << path }
    end

    processor :classify do |image_path, output|
      # Each fork has COW access to @model (no copying!)
      image = load_image(image_path)
      classification = @model.predict(image)
      output << { path: image_path, class: classification }
    end

    consumer :save do |result|
      database.insert(result)
    end
  end
end
```

**Why this works:**
- The 50MB model is loaded once in the parent
- Each forked child accesses it via COW (no copy!)
- True parallelism (no GVL)
- Memory cleaned up after each item

## 4. IPC Fork Execution

**Persistent worker processes with IPC**

```ruby
class IPCTask
  include Minigun::DSL

  execution :ipc_fork, max: 4  # Create 4 persistent workers

  pipeline do
    producer :generate do |output|
      1000.times { |i| output << i }
    end

    processor :compute do |item, output|
      # Workers handle multiple items
      result = expensive_operation(item)
      output << result
    end

    consumer :save do |result|
      save_result(result)
    end
  end
end
```

### How IPC Fork Works

1. Parent spawns `max` worker processes at startup
2. Workers communicate via **bidirectional pipes**
3. Parent distributes items to workers
4. Workers process items and send results back
5. **Workers stay alive** for the entire pipeline
6. Data serialized between processes (Marshal or MessagePack)

### Characteristics

- **Persistent workers** - Like a process pool
- **IPC communication** - Data serialized over pipes
- **True parallelism** - No GVL
- **Process isolation** - Strong separation
- **Setup cost amortized** - Workers reused for many items

### When to Use IPC Fork

✅ **Perfect for:**
- **CPU-intensive long-running work**
- **Expensive setup** (loading models, connections)
- **Processing many items** (amortize fork cost)
- **Worker pool pattern** (like Puma, Unicorn)

❌ **Avoid for:**
- Small, fast operations
- Few items (fork overhead not amortized)
- When serialization overhead is high

### Example: ML Inference Server

```ruby
class MLInference
  include Minigun::DSL

  execution :ipc_fork, max: 4

  pipeline do
    producer :requests do |output|
      # Simulate incoming requests
      loop do
        request = wait_for_request
        output << request
      end
    end

    processor :predict do |request, output|
      # Each worker loads the model once and reuses it
      @model ||= load_expensive_ml_model  # Loaded once per worker

      prediction = @model.predict(request.data)
      output << { request_id: request.id, prediction: prediction }
    end

    consumer :respond do |result|
      send_response(result)
    end
  end
end
```

**Why this works:**
- 4 persistent worker processes
- Each worker loads the model once
- Workers handle many requests
- True parallelism without GVL

## Mixing Strategies

You can mix strategies within a single pipeline:

```ruby
class HybridTask
  include Minigun::DSL

  execution :thread, max: 20  # Default: threads

  pipeline do
    # Threads for I/O-bound work
    producer :fetch_urls, threads: 10 do |output|
      urls.each { |url| output << url }
    end

    processor :download, threads: 20 do |url, output|
      output << HTTP.get(url).body
    end

    # Override: COW fork for CPU-bound work
    processor :process_images, execution: :cow_fork, max: 4 do |html, output|
      images = extract_images(html)
      output << process_with_opencv(images)
    end

    # Override: IPC fork for ML inference
    processor :classify, execution: :ipc_fork, max: 2 do |images, output|
      @model ||= load_ml_model
      output << @model.predict(images)
    end

    # Back to threads for database
    consumer :save, threads: 5 do |results|
      database.insert_many(results)
    end
  end
end
```

## Choosing the Right Strategy

### Decision Tree

```
Is the work CPU-intensive?
├─ No → Use THREADS (I/O-bound)
└─ Yes → Do you have large read-only data?
    ├─ Yes → Use COW FORK
    └─ No → Does setup take long?
        ├─ Yes → Use IPC FORK
        └─ No → Use THREADS or COW FORK
```

### Quick Reference

**Use INLINE when:**
- Debugging or testing
- Operations are trivial (< 1ms)

**Use THREADS when:**
- I/O-bound (network, database, files)
- Shared memory needed
- Operations are thread-safe

**Use COW FORK when:**
- CPU-intensive + large read-only data
- Each item needs isolation
- Memory leaks are a concern

**Use IPC FORK when:**
- CPU-intensive + expensive setup
- Many items to process
- Need persistent worker pools

## Performance Example

Let's compare strategies for the same workload:

```ruby
# 100 items, 100ms CPU work each = 10 seconds sequential

# INLINE: ~10 seconds (no parallelism)
execution :inline

# THREADS: ~10 seconds (GVL limits CPU parallelism)
execution :thread, max: 4

# COW FORK: ~2.5 seconds (true parallelism, 4 processes)
execution :cow_fork, max: 4

# IPC FORK: ~2.5 seconds (true parallelism, 4 workers)
execution :ipc_fork, max: 4
```

For CPU work, forks provide **true parallelism**.

## Key Takeaways

- **Inline** - Debugging and simple pipelines
- **Threads** - I/O-bound work (most common)
- **COW Fork** - CPU work with large shared data
- **IPC Fork** - CPU work with expensive setup
- Mix strategies in one pipeline
- Choose based on workload characteristics

## What's Next?

Now that you understand execution strategies, let's learn how to monitor your pipelines with the HUD.

→ [**Continue to Monitoring**](07_monitoring.md)

---

**See Also:**
- [Execution Guide: Overview](../guides/execution/overview.md) - Detailed comparison
- [COW Fork Guide](../guides/execution/cow_fork.md) - Copy-on-write internals
- [IPC Fork Guide](../guides/execution/ipc_fork.md) - IPC optimization
- [Performance Tuning](../advanced/performance_tuning.md) - Optimization strategies
