# Performance Tuning

Optimize your Minigun pipelines for maximum throughput and efficiency.

## Quick Wins

Before diving deep, try these:

```ruby
# 1. Match fork processes to CPU cores
processor :compute, execution: :cow_fork, max: 8  # For 8-core machine

# 2. High thread count for I/O-bound work
processor :fetch, threads: 50  # Network I/O can handle many threads

# 3. Use batching for database operations
accumulator :batch, max_size: 500  # Bulk inserts
consumer :save { |batch| DB.insert_many(batch) }

# 4. Monitor with HUD
Minigun::HUD.run_with_hud(MyPipeline)
```

## Step 1: Identify Bottlenecks

### Use the HUD

The HUD shows you exactly where your pipeline is slow:

```ruby
require 'minigun/hud'

Minigun::HUD.run_with_hud(MyPipeline)
```

**Look for:**
- **Low throughput** - Stage processing few items/sec
- **High latency** - P95/P99 latency percentiles high
- **Queue buildup** - Queue depth growing over time
- **Imbalanced flow** - Some stages idle while others maxed

### Example HUD Output

```
┌─────────────────────────────────────────────────────┐
│ fetch_users    [████████░░] 85/s  P95: 12ms        │
│ ↓ queue: 2000/5000                                 │
│ enrich        [██░░░░░░░░]  8/s  P95: 523ms  ⚠️   │ ← BOTTLENECK
│ ↓ queue: 0/5000                                    │
│ save          [░░░░░░░░░░]  8/s  P95: 5ms          │
└─────────────────────────────────────────────────────┘
```

The `enrich` stage is the bottleneck (8 items/sec vs 85 upstream).

### Benchmark Code

```ruby
require 'benchmark'

result = Benchmark.measure do
  MyPipeline.new.run
end

puts "Duration: #{result.real}s"
puts "CPU time: #{result.total}s"
puts "Throughput: #{item_count / result.real} items/s"
```

## Step 2: Optimize Execution Strategy

### Match Strategy to Workload

```ruby
# I/O-bound (network, database, files)
processor :fetch_api, threads: 50 do |id, output|
  output << HTTP.get("https://api.example.com/#{id}")
end

# CPU-bound with large shared data
processor :classify, execution: :cow_fork, max: 8 do |data, output|
  output << @large_model.predict(data)  # Shared via COW
end

# CPU-bound with expensive setup
processor :inference, execution: :ipc_fork, max: 4 do |data, output|
  @model ||= load_expensive_model  # Once per worker
  output << @model.predict(data)
end
```

### Decision Matrix

| Workload | Best Strategy | Thread/Process Count |
|----------|--------------|----------------------|
| Database queries | Threads | 10-20 |
| API calls | Threads | 20-50 |
| File I/O | Threads | 10-30 |
| JSON parsing | Threads | 5-10 |
| Image processing | COW Fork | = CPU cores |
| ML inference (large model) | COW Fork | = CPU cores |
| ML inference (expensive load) | IPC Fork | = CPU cores |
| Heavy computation | COW/IPC Fork | = CPU cores |

### Finding Optimal Thread Count

For I/O-bound work, test incrementally:

```ruby
[10, 20, 50, 100].each do |thread_count|
  pipeline = MyPipeline.new(threads: thread_count)

  duration = Benchmark.realtime { pipeline.run }
  throughput = item_count / duration

  puts "#{thread_count} threads: #{throughput.round(2)} items/s"
end

# Output:
# 10 threads: 45.3 items/s
# 20 threads: 87.6 items/s
# 50 threads: 142.8 items/s  ← Best
# 100 threads: 138.2 items/s (diminishing returns)
```

### CPU Core Matching

For CPU-bound work with forks:

```bash
# Check available cores
nproc
# => 8

# In Ruby
require 'etc'
cpu_count = Etc.nprocessors
```

```ruby
# Match max to CPU cores
class Pipeline
  include Minigun::DSL

  def initialize
    @cpu_cores = Etc.nprocessors
  end

  pipeline do
    processor :compute, execution: :cow_fork, max: @cpu_cores do |item, output|
      output << expensive_computation(item)
    end
  end
end
```

## Step 3: Optimize Queue Sizing

### Understanding Queue Size

Queues buffer items between stages:

```ruby
processor :stage, threads: 10, queue_size: 1000 do |item, output|
  # Process item
end
```

**Trade-offs:**
- **Large queues** - Higher memory, smoother flow, absorb bursts
- **Small queues** - Lower memory, faster backpressure, less buffering

### Sizing Guidelines

```ruby
# Fast stages (< 10ms per item)
processor :quick, threads: 10, queue_size: 100

# Medium stages (10-100ms per item)
processor :medium, threads: 20, queue_size: 500  # Default

# Slow stages (> 100ms per item)
processor :slow, threads: 50, queue_size: 2000

# Stages with bursty producers
processor :handle_burst, threads: 10, queue_size: 5000
```

### Calculate From Throughput

```ruby
# Formula: queue_size = throughput × latency × safety_factor

# Example: Stage processes 100 items/s with 50ms latency
throughput = 100  # items/s
latency = 0.05    # seconds
safety_factor = 2 # Buffer for variance

queue_size = throughput * latency * safety_factor
# => 100 × 0.05 × 2 = 10 items (minimum)

# Recommend 100-500 for smoother flow
```

### Monitor Queue Depth

```ruby
after_run do
  stats = root_pipeline.stats

  stages.each do |stage|
    queue_info = stats.queue_depths[stage.name]
    max_depth = queue_info[:max]
    avg_depth = queue_info[:avg]

    if max_depth >= stage.queue_size * 0.9
      puts "⚠️  #{stage.name} queue nearly full (#{max_depth}/#{stage.queue_size})"
    end
  end
end
```

## Step 4: Memory Optimization

### COW Fork Memory Sharing

Load large data in parent before forking:

```ruby
class Pipeline
  include Minigun::DSL

  def initialize
    # Load BEFORE forking (shared via COW)
    @large_lookup_table = load_100mb_table
    @ml_model = load_model  # 500MB
  end

  pipeline do
    producer :items { 10000.times { |i| emit(i) } }

    processor :process, execution: :cow_fork, max: 8 do |item, output|
      # @large_lookup_table and @ml_model shared (no 500MB × 8 copies!)
      result = @ml_model.predict(item, @large_lookup_table[item])
      output << result
    end
  end
end

# Memory: ~500MB total (not 500MB × 8 = 4GB!)
```

### Avoid Memory Leaks

```ruby
# ❌ Accumulating in instance variables
processor :leak do |item, output|
  @results ||= []
  @results << process(item)  # Grows forever!
  output << @results.last
end

# ✅ Don't accumulate
processor :no_leak do |item, output|
  result = process(item)
  output << result  # Process and release
end

# ✅ Use accumulator for intentional batching
accumulator :batch, max_size: 500 do |batch, output|
  output << batch  # Batch released after processing
end
```

### GC Tuning

For memory-intensive pipelines:

```ruby
# Force GC periodically
processor :heavy, execution: :cow_fork, max: 8 do |item, output|
  result = memory_intensive_operation(item)

  # Occasional GC in child processes
  GC.start if rand < 0.1

  output << result
end

# Or set GC environment variables
# RUBY_GC_HEAP_GROWTH_FACTOR=1.1
# RUBY_GC_HEAP_GROWTH_MAX_SLOTS=300000
```

## Step 5: Batch Operations

### Database Bulk Inserts

```ruby
# ❌ Slow: One query per item (1000 items = 1000 queries)
consumer :save do |item|
  database.insert(item)
end

# ✅ Fast: Batched (1000 items = 2 queries for batch size 500)
accumulator :batch, max_size: 500 do |batch, output|
  output << batch
end

consumer :save do |batch|
  database.insert_many(batch)  # Bulk insert
end
```

### Performance Impact

```ruby
# Benchmark batching
[1, 10, 50, 100, 500, 1000].each do |batch_size|
  pipeline = Pipeline.new(batch_size: batch_size)

  duration = Benchmark.realtime { pipeline.run }

  puts "Batch #{batch_size}: #{duration.round(2)}s"
end

# Typical results:
# Batch 1:    45.2s (1000 queries)
# Batch 10:    8.7s (100 queries)
# Batch 50:    2.4s (20 queries)
# Batch 100:   1.5s (10 queries)
# Batch 500:   0.9s (2 queries) ← Best
# Batch 1000:  0.8s (1 query) (marginal improvement)
```

### Optimal Batch Sizes

| Operation | Recommended Batch Size |
|-----------|------------------------|
| Database inserts | 500-1000 |
| Elasticsearch bulk | 500-1000 |
| API bulk endpoints | 100-500 |
| File writes | 1000-5000 |
| In-memory processing | 100-500 |

## Step 6: Platform-Specific Tuning

### MRI Ruby (CRuby)

**GVL Considerations:**

```ruby
# ❌ Threads can't help CPU-bound work (GVL)
processor :compute, threads: 50 do |item, output|
  output << heavy_cpu_work(item)  # Only 1 thread at a time!
end

# ✅ Use forks for true parallelism
processor :compute, execution: :cow_fork, max: 8 do |item, output|
  output << heavy_cpu_work(item)  # All 8 run simultaneously
end
```

**I/O Release GVL:**

```ruby
# ✅ Threads work great for I/O (GVL released during I/O)
processor :fetch, threads: 50 do |url, output|
  output << HTTP.get(url)  # GVL released during network I/O
end
```

### JRuby

**No Fork Support:**

```ruby
# Detect platform
if Minigun::Platform.fork_supported?
  execution :cow_fork, max: 8
else
  # JRuby: use threads (true parallelism without GVL)
  execution :thread, max: 8
end
```

**True Thread Parallelism:**

```ruby
# JRuby threads run in parallel (no GVL)
processor :compute, threads: 8 do |item, output|
  output << heavy_cpu_work(item)  # All 8 truly parallel!
end
```

### TruffleRuby

Similar to JRuby - threads only, but with excellent performance:

```ruby
# Use threads for everything
execution :thread, max: 8

pipeline do
  processor :work, threads: 8 do |item, output|
    output << process(item)  # True parallelism
  end
end
```

## Step 7: Profiling Techniques

### Ruby Profiler

```ruby
require 'ruby-prof'

RubyProf.start

MyPipeline.new.run

result = RubyProf.stop

# Print flat profile
printer = RubyProf::FlatPrinter.new(result)
printer.print(STDOUT)
```

### Stackprof (Sampling Profiler)

```ruby
require 'stackprof'

StackProf.run(mode: :cpu, out: 'tmp/stackprof.dump') do
  MyPipeline.new.run
end

# View results
# stackprof tmp/stackprof.dump --text
```

### Memory Profiling

```ruby
require 'memory_profiler'

report = MemoryProfiler.report do
  MyPipeline.new.run
end

report.pretty_print
```

### Custom Timing

```ruby
class Pipeline
  include Minigun::DSL

  before_run do
    @timings = {}
  end

  pipeline do
    processor :stage1 do |item, output|
      duration = Benchmark.realtime do
        result = process(item)
        output << result
      end

      @mutex.synchronize do
        @timings[:stage1] ||= []
        @timings[:stage1] << duration
      end
    end
  end

  after_run do
    @timings.each do |stage, durations|
      avg = durations.sum / durations.size
      p95 = durations.sort[durations.size * 0.95]

      puts "#{stage}: avg=#{(avg * 1000).round(2)}ms p95=#{(p95 * 1000).round(2)}ms"
    end
  end
end
```

## Real-World Examples

### Example 1: ETL Pipeline

**Before optimization:**

```ruby
class SlowETL
  include Minigun::DSL

  pipeline do
    producer :extract { DB.find_each { |r| emit(r) } }
    processor :transform { |r, output| output << transform(r) }
    consumer :load { |r| TargetDB.insert(r) }  # 1 query per record
  end
end

# Performance: 50 records/sec (20,000 records = 6.7 minutes)
```

**After optimization:**

```ruby
class FastETL
  include Minigun::DSL

  pipeline do
    producer :extract { DB.find_each(batch_size: 1000) { |r| emit(r) } }

    # Parallel transformation
    processor :transform, threads: 10 do |r, output|
      output << transform(r)
    end

    # Batch inserts
    accumulator :batch, max_size: 500 do |batch, output|
      output << batch
    end

    consumer :load, threads: 4 do |batch|
      TargetDB.insert_many(batch)  # Bulk insert
    end
  end
end

# Performance: 2,500 records/sec (20,000 records = 8 seconds)
# Improvement: 50× faster
```

### Example 2: Web Scraper

**Before optimization:**

```ruby
class SlowScraper
  include Minigun::DSL

  pipeline do
    producer :urls { urls.each { |url| emit(url) } }
    processor :fetch { |url, output| output << HTTP.get(url) }  # Sequential
    processor :parse { |html, output| output << parse(html) }
    consumer :save { |data| DB.insert(data) }
  end
end

# Performance: 2 pages/sec (1,000 pages = 8.3 minutes)
```

**After optimization:**

```ruby
class FastScraper
  include Minigun::DSL

  pipeline do
    producer :urls { urls.each { |url| emit(url) } }

    # High concurrency for network I/O
    processor :fetch, threads: 20 do |url, output|
      output << HTTP.get(url)
    end

    # Moderate concurrency for CPU parsing
    processor :parse, threads: 5 do |html, output|
      output << parse(html)
    end

    # Batched saves
    accumulator :batch, max_size: 100 do |batch, output|
      output << batch
    end

    consumer :save do |batch|
      DB.insert_many(batch)
    end
  end
end

# Performance: 15 pages/sec (1,000 pages = 67 seconds)
# Improvement: 7.5× faster
```

### Example 3: Image Processing

**Before optimization:**

```ruby
class SlowImageProcessor
  include Minigun::DSL

  def initialize
    @model = load_model  # 500MB model
  end

  pipeline do
    producer :images { Dir['*.jpg'].each { |path| emit(path) } }

    # Sequential processing
    processor :classify do |path, output|
      image = load_image(path)
      output << @model.predict(image)
    end
  end
end

# Performance: 2 images/sec (1,000 images = 8.3 minutes)
```

**After optimization:**

```ruby
class FastImageProcessor
  include Minigun::DSL

  def initialize
    # Load model in parent (shared via COW)
    @model = load_model  # 500MB shared, not 500MB × 8!
  end

  pipeline do
    producer :images { Dir['*.jpg'].each { |path| emit(path) } }

    # Parallel processing with COW
    processor :classify, execution: :cow_fork, max: 8 do |path, output|
      image = load_image(path)
      output << @model.predict(image)  # Model shared via COW
    end

    # Batched saves
    accumulator :batch, max_size: 100 do |batch, output|
      output << batch
    end

    consumer :save do |batch|
      DB.insert_many(batch)
    end
  end
end

# Performance: 15 images/sec (1,000 images = 67 seconds)
# Improvement: 7.5× faster
# Memory: 500MB total (not 4GB!)
```

## Troubleshooting Performance Issues

### Pipeline Hangs

**Symptom:** Pipeline doesn't complete, appears frozen.

**Causes:**
- Infinite producer loop
- Deadlock in routing
- Stage waiting for input that never comes

**Debug:**
```ruby
# Add timeout
require 'timeout'

Timeout.timeout(3600) do  # 1 hour max
  MyPipeline.new.run
end
```

### High Memory Usage

**Symptom:** Memory grows continuously, eventual OOM.

**Causes:**
- Large queues with slow consumers
- Memory leaks in instance variables
- Not using COW fork properly

**Debug:**
```ruby
# Monitor memory
before_run { @start_mem = `ps -o rss= -p #{Process.pid}`.to_i }

after_run do
  end_mem = `ps -o rss= -p #{Process.pid}`.to_i
  puts "Memory: #{@start_mem}KB → #{end_mem}KB (Δ #{end_mem - @start_mem}KB)"
end
```

### Low Throughput

**Symptom:** Pipeline much slower than expected.

**Causes:**
- Wrong execution strategy
- Too few threads/processes
- Large queues causing memory pressure
- Bottleneck stage

**Debug:** Use HUD to identify bottleneck, then optimize that stage.

## Performance Checklist

Before deploying to production:

- [ ] Profile with HUD to identify bottlenecks
- [ ] Match execution strategy to workload type
- [ ] Set thread/process counts appropriately
- [ ] Use batching for database operations
- [ ] Size queues based on throughput
- [ ] Load shared data before forking (COW)
- [ ] Test with production-like data volume
- [ ] Benchmark and record baseline performance
- [ ] Monitor memory usage over time
- [ ] Plan for resource requirements (CPU, memory)

## Key Takeaways

**For I/O-bound work:**
- Use threads with high concurrency (20-50)
- Queues can be larger for buffering

**For CPU-bound work:**
- Use forks matching CPU core count
- Load shared data before forking (COW)
- Consider IPC fork for expensive setup

**For all pipelines:**
- Batch database operations
- Monitor with HUD
- Profile before optimizing
- Test with realistic data volumes

## Next Steps

- [Monitoring](07_monitoring.md) - Using HUD to find bottlenecks
- [Execution Strategies](06_execution_strategies.md) - Deep dive on strategies
- [Deployment](08_deployment.md) - Production deployment
- [Recipes](../recipes/) - Optimized real-world examples

---

**Ready to optimize?** [Start with the HUD →](07_monitoring.md)
