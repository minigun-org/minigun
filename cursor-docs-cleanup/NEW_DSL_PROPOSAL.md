# The New DSL: What You'll Actually Write

## Core Idea: Write Less, Get More

**Most pipelines need zero configuration - they just work.**

---

## Example 1: The Simplest Case (99% of pipelines)

```ruby
class MyPipeline
  include Minigun::DSL

  # Generate some data
  producer :load_files do
    Dir.glob("*.csv").each { |file| emit(file) }
  end

  # Process each file
  processor :parse_csv do |filename|
    data = CSV.read(filename)
    emit(data)
  end

  # Save results
  consumer :save_to_db do |data|
    database.insert(data)
  end
end
```

**That's it!** The system automatically:
- Runs stages in the most efficient way
- Uses threads when it makes sense
- Cleans up after itself

---

## Example 2: Large Dataset (Need more workers)

```ruby
class BigDataPipeline
  include Minigun::DSL

  # Tell system: "I want more workers"
  workers 20  # Use up to 20 threads

  producer :fetch_urls do
    urls.each { |url| emit(url) }
  end

  processor :download do |url|
    emit(HTTP.get(url))
  end

  consumer :save do |data|
    storage.save(data)
  end
end
```

**New thing**: `workers 20`
- Means: "I have lots of items, use up to 20 threads"
- System handles everything else automatically

---

## Example 3: Heavy CPU Work (Need process isolation)

```ruby
class ImagePipeline
  include Minigun::DSL

  workers 10

  producer :load_images do
    image_files.each { |file| emit(file) }
  end

  # This is CPU-intensive, use separate processes
  processor :resize_image, isolate: true do |file|
    # Expensive image processing
    resized = ImageMagick.resize(file)
    emit(resized)
  end

  consumer :save do |image|
    image.save
  end
end
```

**New thing**: `isolate: true`
- Means: "This work is heavy, run it in a separate process"
- Prevents one slow image from blocking others
- System manages the processes for you

---

## Example 4: Batching (Process groups of items)

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

  # Collect 100 emails before sending
  batch 100

  # This receives an array of 100 items at once
  consumer :send_bulk do |emails|
    EmailService.bulk_send(emails)  # One API call for 100 emails
  end
end
```

**New thing**: `batch 100`
- Means: "Collect 100 items before processing"
- `send_bulk` gets an array of 100 emails
- Much more efficient than sending one at a time

---

## Example 5: Multiple Paths (Fan-out)

```ruby
class NotificationPipeline
  include Minigun::DSL

  producer :new_orders do
    Order.pending.each { |order| emit(order) }
  end

  # Send to multiple places
  processor :notify_customer, to: :done do |order|
    CustomerMailer.send(order)
    emit(order)
  end

  processor :notify_warehouse, to: :done do |order|
    WarehouseAPI.notify(order)
    emit(order)
  end

  consumer :done do |order|
    order.mark_notified!
  end
end
```

**This is the same as before** - routing with `to:` still works

---

## Example 6: Expert Mode (Rare - only if needed)

```ruby
class AdvancedPipeline
  include Minigun::DSL

  workers 20            # Up to 20 threads
  processes 4           # Up to 4 separate processes

  producer :stream_data do
    stream.each { |item| emit(item) }
  end

  # Most work: use threads (fast, shared memory)
  processor :validate do |item|
    emit(item) if valid?(item)
  end

  # Heavy work: use processes (isolated, won't block)
  processor :process, isolate: true do |item|
    result = expensive_computation(item)
    emit(result)
  end

  # For experts: force separate process (rarely needed)
  processor :untrusted, force: :process do |item|
    # Run untrusted code in isolated process
    emit(evaluate_user_code(item))
  end

  consumer :save do |item|
    db.save(item)
  end
end
```

**Expert options**:
- `workers N` - How many threads to use
- `processes N` - How many separate processes to allow
- `isolate: true` - This stage is heavy, use a separate process
- `force: :process` - Always use a process (for experts)

---

## Summary: What You Write

### Default (no config needed)
```ruby
producer :name do
  # ... produce items ...
end

processor :name do |item|
  # ... process item ...
end

consumer :name do |item|
  # ... consume item ...
end
```

### More Workers
```ruby
workers 20  # Use more threads
```

### Heavy Work
```ruby
processor :name, isolate: true do |item|
  # Heavy CPU work - runs in separate process
end
```

### Batching
```ruby
batch 100  # Collect 100 items

consumer :name do |batch|
  # batch is an array of 100 items
end
```

### Multiple Processes
```ruby
workers 20     # Threads
processes 4    # Processes
```

---

## What Changed From Old API?

### REMOVED (confusing)
```ruby
# ❌ OLD - What does this mean?
spawn_fork :heavy do |item|
end

# ❌ OLD - What's the difference?
spawn_thread :work do |item|
end

# ❌ OLD - Multiple configs
max_threads 10
max_processes 4
max_retries 3
```

### NEW (clear)
```ruby
# ✅ NEW - Clear: this is heavy work
processor :heavy, isolate: true do |item|
end

# ✅ NEW - Default: uses threads automatically
processor :work do |item|
end

# ✅ NEW - One config
workers 10
processes 4
retries 3
```

---

## Decision Tree for Users

**"How many items?"**
- Less than 100 → Don't configure anything
- More than 100 → Add `workers 20` (or higher number)

**"Is my work heavy (CPU-intensive)?"**
- No (I/O, database, network) → Don't configure anything
- Yes (image processing, parsing, computation) → Add `isolate: true`

**"Do I need batching?"**
- No → Don't configure anything
- Yes → Add `batch N` before your consumer

**That's it!** 95% of pipelines need zero or one line of configuration.

---

## Mental Model

Think of it like a restaurant kitchen:

- **producer** = The order comes in
- **processor** = A chef prepares something
- **consumer** = The dish goes out

**workers** = How many chefs you have
**isolate: true** = This dish needs a separate station (heavy work)
**batch** = Wait for 10 orders before cooking (more efficient)

---

## What Happens Automatically

The system figures out:
1. **Which stages can run together** (in same thread) - faster
2. **Which stages need separation** (different threads) - parallel
3. **When to use processes** (if you said `isolate: true`)
4. **How to clean up** (closes threads/processes automatically)
5. **How to handle errors** (propagates them correctly)

You just write your business logic. The system handles the complexity.

---

## Complete Before/After Example

### Before (Current API - Confusing)
```ruby
class MyPipeline
  include Minigun::DSL

  max_threads 10
  max_processes 4
  max_retries 3

  producer :gen do
    emit(data)
  end

  processor :work, strategy: :threaded, to: :heavy do |item|
    emit(item)
  end

  spawn_fork :heavy, to: :save do |item|
    emit(process(item))
  end

  consumer :save, strategy: :threaded do |item|
    store(item)
  end
end
```

### After (New API - Clear)
```ruby
class MyPipeline
  include Minigun::DSL

  workers 10
  processes 4
  retries 3

  producer :gen do
    emit(data)
  end

  processor :work do |item|
    emit(item)
  end

  processor :heavy, isolate: true do |item|
    emit(process(item))
  end

  consumer :save do |item|
    store(item)
  end
end
```

**Differences:**
- `max_threads` → `workers` (clearer name)
- `strategy: :threaded` → (removed, automatic)
- `spawn_fork` → `processor` with `isolate: true` (clearer intent)
- Routing with `to:` stays the same

**Result:** Same behavior, but much clearer to read and write!

