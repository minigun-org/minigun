# Final DSL Proposal: Block-Based Execution Scoping

## The Core Idea: Visual Execution Groups

Use `threads(N)` and `processes(N)` blocks to **visually show** where each stage runs.

---

## Example 1: Simple Pipeline (Default Threads)

```ruby
class MyPipeline
  include Minigun::DSL

  # No block needed - uses default threads automatically
  producer :load_files do
    Dir.glob("*.csv").each { |file| emit(file) }
  end

  processor :parse_csv do |filename|
    data = CSV.read(filename)
    emit(data)
  end

  consumer :save_to_db do |data|
    database.insert(data)
  end
end
```

**Default behavior**: All stages use threads (pool size: 5) automatically.

---

## Example 2: Heavy CPU Work (Explicit Processes)

```ruby
class ImagePipeline
  include Minigun::DSL

  # I/O work - uses default threads
  producer :load_images do
    Dir.glob("images/*.jpg").each { |file| emit(file) }
  end

  # CPU-intensive work - explicit process block
  processes(4) do
    processor :resize do |file|
      resized = ImageMagick.resize(file, '800x600')
      emit(resized)
    end

    processor :optimize do |file|
      optimized = ImageOptim.optimize(file)
      emit(optimized)
    end
  end

  # I/O work - back to default threads
  consumer :save do |image|
    storage.upload(image)
  end
end
```

**Clear intent**: CPU-intensive stages are visually grouped in the `processes` block.

---

## Example 3: Multiple Thread Pools

```ruby
class WebCrawler
  include Minigun::DSL

  # Small thread pool for generating URLs
  threads(5) do
    producer :seed_urls do
      starting_urls.each { |url| emit(url) }
    end
  end

  # Large thread pool for downloading (I/O-bound)
  threads(50) do
    processor :download do |url|
      html = HTTP.get(url)
      emit(html)
    end

    processor :extract_links do |html|
      links = Nokogiri::HTML(html).css('a').map { |a| a['href'] }
      links.each { |link| emit(link) }
    end
  end

  # Small thread pool for saving
  threads(10) do
    consumer :save_to_db do |html|
      database.insert(html)
    end
  end
end
```

**Flexibility**: Different parts of the pipeline can have different pool sizes.

---

## Example 4: Mixed Workload

```ruby
class DataPipeline
  include Minigun::DSL

  # I/O: fetch from S3
  producer :fetch_files do
    s3.list_objects.each { |file| emit(file) }
  end

  # I/O: download files (uses default threads)
  processor :download do |file|
    content = s3.download(file)
    emit(content)
  end

  # CPU: parse large files
  processes(4) do
    processor :parse_json do |content|
      data = JSON.parse(content)  # Can be expensive
      emit(data)
    end

    processor :transform do |data|
      transformed = expensive_transformation(data)
      emit(transformed)
    end
  end

  # I/O: save to database (back to default threads)
  consumer :save_to_db do |data|
    database.bulk_insert(data)
  end
end
```

**Smart separation**: I/O work uses threads, CPU work uses processes.

---

## Example 5: Batching with Blocks

```ruby
class EmailPipeline
  include Minigun::DSL

  producer :fetch_users do
    User.all.each { |user| emit(user) }
  end

  processor :prepare_email do |user|
    email = create_email(user)
    emit(email)
  end

  # Collect 100 emails, then process as batch
  batch 100

  # Send in bulk using threads
  threads(5) do
    consumer :send_bulk do |emails|
      EmailService.bulk_send(emails)  # emails is array of 100
    end
  end
end
```

**Batching works naturally** with execution blocks.

---

## Example 6: Routing Across Blocks

```ruby
class NotificationPipeline
  include Minigun::DSL

  producer :new_orders do
    Order.pending.each { |order| emit(order) }
  end

  # Fan out to multiple paths
  threads(20) do
    processor :notify_customer, to: :log do |order|
      CustomerMailer.send(order)
      emit(order)
    end

    processor :notify_warehouse, to: :log do |order|
      WarehouseAPI.notify(order)
      emit(order)
    end
  end

  # Merge back together
  consumer :log do |order|
    logger.info("Notified: #{order.id}")
  end
end
```

**Routing still works**: The `to:` keyword connects stages across blocks naturally.

---

## Example 7: Expert Mode (Ractors)

```ruby
class ComputePipeline
  include Minigun::DSL

  producer :generate_numbers do
    1_000_000.times { |i| emit(i) }
  end

  # Use ractors for true parallelism (Ruby 3.0+)
  ractors(8) do
    processor :calculate_prime do |n|
      result = is_prime?(n)  # Pure computation
      emit(result) if result
    end
  end

  consumer :save do |prime|
    primes_db.insert(prime)
  end
end
```

**Ractors available** for true parallel computation (Ruby 3.0+).

---

## Example 8: Everything Together

```ruby
class ComplexPipeline
  include Minigun::DSL

  # Generate data (default threads)
  producer :stream_from_kafka do
    kafka.consume { |msg| emit(msg) }
  end

  # Light validation (default threads)
  processor :validate do |msg|
    emit(msg) if valid?(msg)
  end

  # Heavy parsing (processes)
  processes(4) do
    processor :parse_xml do |msg|
      data = Nokogiri::XML.parse(msg.body)  # CPU-intensive
      emit(data)
    end
  end

  # Transform (default threads)
  processor :transform do |data|
    transformed = data.map(&:upcase)
    emit(transformed)
  end

  # Batch before saving
  batch 100

  # Bulk save (larger thread pool)
  threads(20) do
    consumer :bulk_save do |batch|
      database.bulk_insert(batch)
    end
  end
end
```

**Complete example** showing all features working together.

---

## Simple Rules

### 1. No block = default threads
```ruby
producer :gen do
  # Uses threads(5) automatically
end
```

### 2. Wrap CPU-intensive stages in processes
```ruby
processes(4) do
  processor :heavy do |item|
    # Runs in separate process
  end
end
```

### 3. Use larger thread pools for lots of I/O
```ruby
threads(50) do
  processor :download do |url|
    # 50 simultaneous downloads
  end
end
```

### 4. Batching works anywhere
```ruby
batch 100

consumer :save do |batch|
  # batch is array of 100 items
end
```

---

## Implementation Notes

### What happens inside a block?

```ruby
threads(20) do
  # All stages defined here:
  # - Share a thread pool of size 20
  # - Are tagged with execution_context: { type: :thread, pool_size: 20 }
  # - Execute with that context at runtime
end
```

### What about stages outside blocks?

```ruby
# Stage outside any block
producer :gen do
  # Uses default: threads(5)
end
```

### Can blocks be nested?

```ruby
# No - blocks don't nest, they're flat scopes
threads(20) do
  processes(4) do  # ❌ Error: can't nest execution blocks
  end
end
```

### Can I override per-stage?

```ruby
# For expert users who need fine control
threads(20) do
  # Most stages use the thread pool
  processor :normal do |item|
    emit(item)
  end

  # But this one overrides to use a process
  processor :special, force: :process do |item|
    emit(item)
  end
end
```

---

## Comparison: Old vs New

### Old API (Current)
```ruby
class Pipeline
  include Minigun::DSL

  max_threads 20
  max_processes 4
  max_retries 3

  producer :gen do
    emit(data)
  end

  processor :work, strategy: :threaded do |item|
    emit(item)
  end

  spawn_fork :heavy do |item|
    emit(process(item))
  end

  consumer :save, strategy: :threaded do |item|
    store(item)
  end
end
```

### New API (Proposed)
```ruby
class Pipeline
  include Minigun::DSL

  retries 3

  producer :gen do
    emit(data)
  end

  threads(20) do
    processor :work do |item|
      emit(item)
    end
  end

  processes(4) do
    processor :heavy do |item|
      emit(process(item))
    end
  end

  consumer :save do |item|
    store(item)
  end
end
```

**Benefits:**
- ✅ Visual grouping shows execution model
- ✅ No confusing `spawn_*` methods
- ✅ No `strategy:` options
- ✅ Pool sizes are scoped to where they're used
- ✅ Default is sensible (threads)
- ✅ Clear intent

---

## Migration Strategy

### Phase 1: Add new syntax (both work)
```ruby
# Old syntax still works
spawn_fork :heavy do |item|
end

# New syntax available
processes(4) do
  processor :heavy do |item|
  end
end
```

### Phase 2: Update examples
```ruby
# Update all examples to new syntax
# Add deprecation warnings to old syntax
```

### Phase 3: Remove old syntax
```ruby
# Delete: spawn_fork, spawn_thread, spawn_ractor
# Delete: strategy: option
# Delete: max_threads, max_processes (or keep as aliases)
```

---

## Final Recommendation

**This is the way!** The block-based syntax:

1. **Visually clear** - see at a glance what runs where
2. **Flexible** - different pool sizes for different groups
3. **Simple default** - stages outside blocks just work
4. **Natural Ruby** - `do/end` blocks are idiomatic
5. **Scoped** - pool size is local to the block

**Should we proceed with implementation?**

