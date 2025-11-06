# Concurrency

One of Minigun's most powerful features is built-in concurrency. Process multiple items in parallel using threads or processes with just one keyword.

## Sequential by Default

Without any configuration, stages process items one at a time:

```ruby
pipeline do
  producer :generate do |output|
    10.times { |i| output << i }
  end

  processor :slow_work do |item, output|
    sleep 1  # Simulates slow operation
    output << item * 2
  end

  consumer :print do |item|
    puts item
  end
end

# Takes ~10 seconds (1 second × 10 items)
```

## Adding Thread Concurrency

Use `threads:` to process multiple items concurrently:

```ruby
pipeline do
  producer :generate do |output|
    10.times { |i| output << i }
  end

  processor :slow_work, threads: 5 do |item, output|
    sleep 1
    output << item * 2
  end

  consumer :print do |item|
    puts item
  end
end

# Takes ~2 seconds (5 threads, 10 items)
```

**What happened?**
- The `slow_work` stage now uses 5 concurrent threads
- Multiple items are processed simultaneously
- Total time reduced from 10s to ~2s

## When to Use Threads

Threads are perfect for **I/O-bound** operations:

### ✅ Good Use Cases for Threads

**Network requests:**
```ruby
processor :fetch_data, threads: 20 do |url, output|
  response = HTTP.get(url)
  output << response.body
end
```

**Database queries:**
```ruby
processor :fetch_user, threads: 10 do |user_id, output|
  user = User.find(user_id)
  output << user
end
```

**File I/O:**
```ruby
processor :read_files, threads: 8 do |filepath, output|
  content = File.read(filepath)
  output << content
end
```

### ❌ Poor Use Cases for Threads

**CPU-intensive work** (due to Ruby's GVL):
```ruby
# Threads won't help much here
processor :calculate, threads: 10 do |data, output|
  # Heavy computation is limited by GVL
  output << complex_calculation(data)
end
```

For CPU-bound work, use **processes** instead (covered in the next lesson).

## Thread Pool Sizing

How many threads should you use?

### Conservative (Default)
```ruby
processor :work, threads: 5 do |item, output|
  # Good starting point
end
```

### I/O-Heavy Work
```ruby
processor :api_calls, threads: 50 do |item, output|
  # High concurrency for network requests
end
```

### CPU-Bound Work
```ruby
processor :compute, threads: 2 do |item, output|
  # Low concurrency - threads don't help much
end
```

**Rule of Thumb:**
- **I/O-bound**: 10-50 threads (or more for network requests)
- **CPU-bound**: 1-2 threads (or use processes)
- **Mixed**: 5-10 threads

## Thread Safety

When using threads, be careful with shared state:

### ❌ Not Thread-Safe

```ruby
class Pipeline
  include Minigun::DSL

  def initialize
    @counter = 0  # Shared variable
  end

  pipeline do
    producer :generate do |output|
      100.times { |i| output << i }
    end

    processor :count, threads: 10 do |item, output|
      @counter += 1  # RACE CONDITION!
      output << item
    end
  end
end
```

### ✅ Thread-Safe with Mutex

```ruby
class Pipeline
  include Minigun::DSL

  def initialize
    @counter = 0
    @mutex = Mutex.new
  end

  pipeline do
    producer :generate do |output|
      100.times { |i| output << i }
    end

    processor :count, threads: 10 do |item, output|
      @mutex.synchronize { @counter += 1 }
      output << item
    end
  end
end
```

### ✅ Thread-Safe with Concurrent Data Structures

```ruby
require 'concurrent'

class Pipeline
  include Minigun::DSL

  def initialize
    @results = Concurrent::Array.new
  end

  pipeline do
    processor :collect, threads: 10 do |item, output|
      @results << item  # Thread-safe!
      output << item
    end
  end
end
```

## Practical Example: Web Scraper

Let's build a parallel web scraper:

```ruby
require 'http'

class WebScraper
  include Minigun::DSL

  attr_accessor :results

  def initialize
    @results = Concurrent::Array.new
  end

  pipeline do
    # Generate URLs to scrape
    producer :urls do |output|
      urls = [
        'https://example.com/page1',
        'https://example.com/page2',
        # ... 100 URLs
      ]
      urls.each { |url| output << url }
    end

    # Fetch pages in parallel (I/O-bound)
    processor :fetch, threads: 20 do |url, output|
      begin
        response = HTTP.timeout(10).get(url)
        output << { url: url, body: response.body.to_s }
      rescue => e
        puts "Error fetching #{url}: #{e.message}"
      end
    end

    # Parse HTML (CPU-bound, but relatively fast)
    processor :parse, threads: 5 do |page, output|
      doc = Nokogiri::HTML(page[:body])
      links = doc.css('a').map { |link| link['href'] }
      output << { url: page[:url], links: links }
    end

    # Store results (thread-safe array)
    consumer :store do |page_data|
      results << page_data
    end
  end
end

scraper = WebScraper.new
scraper.run
puts "Scraped #{scraper.results.size} pages"
```

**Why this works:**
- `fetch` uses 20 threads because it's I/O-bound (network requests)
- `parse` uses 5 threads because it's moderately CPU-bound
- Results are stored in a thread-safe `Concurrent::Array`

## Multiple Concurrent Stages

You can parallelize multiple stages:

```ruby
pipeline do
  producer :generate do |output|
    100.times { |i| output << i }
  end

  # First stage: 10 threads
  processor :step_1, threads: 10 do |item, output|
    result = slow_operation_1(item)
    output << result
  end

  # Second stage: 5 threads
  processor :step_2, threads: 5 do |item, output|
    result = slow_operation_2(item)
    output << result
  end

  # Final stage: 20 threads
  consumer :save, threads: 20 do |item|
    database.save(item)
  end
end
```

Each stage has its own thread pool, operating independently.

## Global Thread Limits

Set a maximum thread count for the entire pipeline:

```ruby
class Pipeline
  include Minigun::DSL

  max_threads 20  # Global limit

  pipeline do
    processor :stage_1, threads: 15 do |item, output|
      # Uses 15 threads
    end

    processor :stage_2, threads: 10 do |item, output|
      # Uses 10 threads
    end

    # Total: 25 threads requested, but limited to 20
  end
end
```

## Performance Tips

### 1. Profile First
Measure your pipeline to find bottlenecks:

```ruby
# Use the HUD to identify slow stages
task = MyPipeline.new
task.run(background: true)
task.hud  # Shows bottlenecks in real-time
```

### 2. Start Conservative
Begin with low thread counts and increase as needed:

```ruby
# Start here
processor :work, threads: 5 do |item, output|
  # ...
end

# If this stage is slow, increase threads
processor :work, threads: 20 do |item, output|
  # ...
end
```

### 3. Match Workload
Different stages may need different concurrency levels:

```ruby
pipeline do
  processor :fetch_api, threads: 50 do |id, output|
    # High concurrency for network
  end

  processor :process_data, threads: 5 do |data, output|
    # Lower concurrency for CPU work
  end
end
```

### 4. Watch Memory
More threads = more memory:

```ruby
# High memory usage with 100 threads
processor :work, threads: 100 do |large_data, output|
  # Each thread holds large_data in memory
end
```

## Backpressure

Minigun automatically manages **backpressure** using bounded queues:

```ruby
pipeline do
  # Fast producer
  producer :generate do |output|
    1_000_000.times { |i| output << i }
  end

  # Slow consumer
  consumer :process, threads: 2 do |item|
    sleep 0.1
    process(item)
  end
end
```

**What happens:**
1. Producer tries to emit 1,000,000 items quickly
2. Consumer's input queue fills up (default max: 1000 items)
3. Producer **blocks** when queue is full
4. Producer resumes when consumer catches up

This prevents memory exhaustion.

## Key Takeaways

- Use `threads:` parameter to add concurrency
- Threads are great for **I/O-bound** work
- Always use `Mutex` or concurrent data structures for shared state
- Profile your pipeline to find bottlenecks
- Start with conservative thread counts
- Minigun provides automatic backpressure

## What's Next?

Threads are great for I/O, but what about CPU-intensive work? Next, we'll learn about **execution strategies** including process-based parallelism.

→ [**Continue to Execution Strategies**](06_execution_strategies.md)

---

**See Also:**
- [Configuration Guide](../guides/configuration.md) - All concurrency options
- [Performance Tuning](../advanced/performance_tuning.md) - Optimization strategies
- [Example: Web Crawler](../../examples/10_web_crawler.rb) - Parallel scraping
