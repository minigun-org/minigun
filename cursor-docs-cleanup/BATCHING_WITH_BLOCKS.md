# Batching with Block-Based Execution

## Core Concept: batch is a Pipeline Boundary

`batch N` sits **between stages** - it's not inside an execution block, it's a collection point.

---

## Example 1: Simple Batching

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

  # Collect 100 emails before processing
  batch 100

  # Consumer receives array of 100 items
  consumer :send_bulk do |emails|
    EmailService.bulk_send(emails)  # One API call for 100 emails
  end
end
```

**How it works:**
1. Producer emits individual users
2. Processor emits individual emails
3. **batch 100** collects them into groups of 100
4. Consumer receives arrays of 100 emails

---

## Example 2: Batching with Processes

```ruby
class ImagePipeline
  include Minigun::DSL

  producer :load_images do
    Dir.glob("images/*.jpg").each { |file| emit(file) }
  end

  # Collect 50 images
  batch 50

  # Process batch of 50 in parallel processes
  processes(4) do
    consumer :resize_batch do |images|
      # images is array of 50 filenames
      images.each do |img|
        ImageMagick.resize(img, '800x600')
      end
    end
  end
end
```

**Why this works:**
- Batch collects 50 images
- Each batch goes to a process
- 4 processes can work on different batches in parallel

---

## Example 3: Batching with Large Thread Pool

```ruby
class DataPipeline
  include Minigun::DSL

  threads(50) do
    producer :fetch_urls do
      urls.each { |url| emit(url) }
    end

    processor :download do |url|
      html = HTTP.get(url)
      emit(html)
    end
  end

  # Batch 100 HTML pages
  batch 100

  threads(10) do
    consumer :bulk_insert do |pages|
      # pages is array of 100 HTML strings
      database.bulk_insert(pages)
    end
  end
end
```

**Two different thread pools:**
- 50 threads for downloading (I/O-bound)
- Batch boundary
- 10 threads for database inserts

---

## Example 4: Multiple Batches in Pipeline

```ruby
class ComplexPipeline
  include Minigun::DSL

  producer :stream do
    stream.each { |item| emit(item) }
  end

  # First batch: collect for validation
  batch 50

  processor :validate_batch do |items|
    valid_items = items.select { |i| valid?(i) }
    valid_items.each { |i| emit(i) }  # Re-emit individually
  end

  processor :transform do |item|
    emit(transform(item))
  end

  # Second batch: collect for bulk save
  batch 100

  consumer :bulk_save do |items|
    database.bulk_insert(items)
  end
end
```

**Multiple batching points** in the same pipeline.

---

## Example 5: Batching Before Heavy Processing

```ruby
class ParserPipeline
  include Minigun::DSL

  producer :load_files do
    Dir.glob("data/*.json").each { |file| emit(file) }
  end

  # Batch files together
  batch 25

  # Each process gets a batch of 25 files
  processes(4) do
    consumer :parse_batch do |files|
      files.each do |file|
        data = JSON.parse(File.read(file))  # Expensive
        process(data)
      end
    end
  end
end
```

**Copy-on-Write optimization**: Batch before forking to maximize shared memory.

---

## Example 6: Dynamic Batch Size

```ruby
class AdaptivePipeline
  include Minigun::DSL

  producer :stream do
    stream.each { |item| emit(item) }
  end

  # Batch based on time or size
  batch size: 100, timeout: 5.seconds

  consumer :process_batch do |items|
    # Receives batch when either:
    # - 100 items collected, OR
    # - 5 seconds elapsed
    process(items)
  end
end
```

**Smart batching** with timeout (potential future feature).

---

## How Batching Works Internally

```ruby
producer :gen do
  emit(1)
  emit(2)
  emit(3)
  # ... emits 100 items
end

batch 100  # ← This creates an AccumulatorStage

consumer :save do |batch|
  # batch = [1, 2, 3, ..., 100]
end
```

**Under the hood:**
1. `batch 100` creates an `AccumulatorStage` with `max_size: 100`
2. It collects items until size reaches 100
3. Emits the collected array to next stage
4. Consumer receives array instead of individual items

---

## Batching Pattern: When to Use

### Use batching when:
```ruby
# ✅ Bulk database operations
batch 100
consumer :bulk_insert do |items|
  database.bulk_insert(items)  # One query instead of 100
end

# ✅ Bulk API calls
batch 50
consumer :bulk_send do |emails|
  EmailService.bulk_send(emails)  # One API call instead of 50
end

# ✅ Before heavy processing
batch 25
processes(4) do
  consumer :parse_batch do |files|
    files.each { |f| parse(f) }  # Process batch in separate process
  end
end
```

### Don't batch when:
```ruby
# ❌ Processing is independent
processor :transform do |item|
  emit(item * 2)  # No benefit from batching
end

# ❌ Need immediate processing
consumer :send_notification do |order|
  notify_customer(order)  # Don't make customer wait for batch
end
```

---

## Alternative Syntax Ideas

### Current proposal (standalone):
```ruby
producer :gen do
  emit(data)
end

batch 100  # Standalone declaration

consumer :save do |batch|
  # ...
end
```

### Alternative 1 (explicit accumulator stage):
```ruby
producer :gen do
  emit(data)
end

accumulator :batcher, size: 100

consumer :save do |batch|
  # ...
end
```

### Alternative 2 (method on stage):
```ruby
producer :gen do
  emit(data)
end

processor :collect, batch: 100 do |items|
  # items is already a batch
  emit(items)
end

consumer :save do |batch|
  # ...
end
```

### Alternative 3 (inside consumer block):
```ruby
producer :gen do
  emit(data)
end

# Consumer specifies it wants batches
consumer :save, batch: 100 do |batch|
  # Automatically receives batches of 100
end
```

**I prefer the standalone `batch 100`** - it's clear and sits naturally between stages.

---

## Complete Real-World Example

```ruby
class DataProcessingPipeline
  include Minigun::DSL

  # Fetch data from API (I/O-bound)
  threads(20) do
    producer :fetch_from_api do
      pages = 1..100
      pages.each do |page|
        response = API.get("/data?page=#{page}")
        response.items.each { |item| emit(item) }
      end
    end
  end

  # Light validation (uses default threads)
  processor :validate do |item|
    emit(item) if valid?(item)
  end

  # Batch before heavy processing
  batch 50

  # Parse in separate processes (CPU-bound)
  processes(4) do
    processor :parse_batch do |items|
      # Each process gets 50 items
      items.each do |item|
        parsed = expensive_parse(item)
        emit(parsed)
      end
    end
  end

  # Transform individual items (uses default threads)
  processor :transform do |item|
    emit(transform(item))
  end

  # Batch again for bulk database insert
  batch 100

  # Bulk save to database
  threads(10) do
    consumer :bulk_save do |items|
      database.bulk_insert(items)
    end
  end
end
```

**Everything together:**
- Multiple thread pools for different I/O patterns
- Process pool for CPU-intensive parsing
- Two batching points (one before parsing, one before saving)
- Clear visual separation of concerns

---

## Summary

### Batching Syntax
```ruby
batch 100  # Standalone between stages
```

### Where It Goes
```ruby
producer :gen do
  emit(individual_items)
end

batch 100  # ← Between producer and consumer

consumer :save do |batch|
  # batch is array of 100 items
end
```

### With Execution Blocks
```ruby
threads(20) do
  producer :gen do
    emit(items)
  end
end

batch 100  # ← Outside execution blocks

processes(4) do
  consumer :save do |batch|
    # Process each batch
  end
end
```

**Key insight**: `batch` is a pipeline boundary, not tied to execution context. It sits between stages naturally.

---

Does this make sense? The `batch N` declaration sits between stages, and the consumer that receives the batch can be in any execution block (threads, processes, or default).

