# Understanding Stages

Stages are the building blocks of Minigun pipelines. Each stage has a specific role in processing data. Let's explore the four main stage types.

## The Four Stage Types

### 1. Producer
**Generates data** - Has no input, only output

```ruby
producer :generate do |output|
  10.times { |i| output << i }
end
```

### 2. Processor
**Transforms data** - Has both input and output

```ruby
processor :double do |number, output|
  output << (number * 2)
end
```

### 3. Accumulator
**Batches items** - Collects multiple items before emitting

```ruby
accumulator :batch, max_size: 5 do |batch, output|
  output << batch
end
```

### 4. Consumer
**Final processing** - Has input, no output

```ruby
consumer :save do |item|
  database.insert(item)
end
```

## Producers in Detail

Producers are the **entry points** to your pipeline. They generate or fetch data from external sources.

### Basic Producer

```ruby
producer :numbers do |output|
  (1..100).each { |n| output << n }
end
```

### Fetching from Database

```ruby
producer :fetch_users do |output|
  User.find_each(batch_size: 1000) do |user|
    output << user
  end
end
```

### Reading from Files

```ruby
producer :read_log do |output|
  File.foreach('log.txt') do |line|
    output << line.chomp
  end
end
```

### API Requests

```ruby
producer :fetch_data do |output|
  response = HTTP.get('https://api.example.com/data')
  JSON.parse(response.body).each { |item| output << item }
end
```

### Infinite Producers

Producers can run indefinitely for stream processing:

```ruby
producer :monitor do |output|
  loop do
    metrics = gather_metrics
    output << metrics
    sleep 1
  end
end
```

**Note:** Use Ctrl+C or the HUD to stop infinite pipelines.

## Processors in Detail

Processors **transform** data. They receive input, do something with it, and emit output.

### Basic Transformation

```ruby
processor :uppercase do |text, output|
  output << text.upcase
end
```

### Filtering

Don't emit items you want to filter out:

```ruby
processor :adults_only do |person, output|
  output << person if person.age >= 18
end
```

### Splitting

One input can produce multiple outputs:

```ruby
processor :split_sentences do |paragraph, output|
  paragraph.split(/[.!?]+/).each do |sentence|
    output << sentence.strip
  end
end
```

### Enrichment

Add data from external sources:

```ruby
processor :enrich_user do |user, output|
  profile = fetch_profile(user.id)
  output << user.merge(profile: profile)
end
```

### Validation

```ruby
processor :validate do |record, output|
  if record.valid?
    output << record
  else
    logger.warn("Invalid record: #{record.errors}")
  end
end
```

## Accumulators in Detail

Accumulators **batch multiple items** into groups before emitting them downstream. This is useful for bulk operations.

### Basic Batching

```ruby
accumulator :batch, max_size: 100 do |batch, output|
  output << batch
end
```

When `max_size` items accumulate, they're emitted as an array.

### Using Batches

```ruby
pipeline do
  producer :generate do |output|
    1000.times { |i| output << i }
  end

  accumulator :batch, max_size: 50 do |batch, output|
    output << batch
  end

  consumer :bulk_insert do |batch|
    database.insert_many(batch)
    puts "Inserted #{batch.size} records"
  end
end
```

### Custom Batching Logic

You can implement custom batching in a processor:

```ruby
processor :batch_by_type do |item, output|
  @batches ||= Hash.new { |h, k| h[k] = [] }
  @batches[item.type] << item

  # Emit when any batch is full
  @batches.each do |type, batch|
    if batch.size >= 50
      output << { type: type, items: batch }
      batch.clear
    end
  end
end
```

## Consumers in Detail

Consumers are the **endpoints** of your pipeline. They perform final processing without emitting further data.

### Saving to Database

```ruby
consumer :save do |record|
  database.insert(record)
end
```

### Writing to Files

```ruby
consumer :write_csv do |row|
  CSV.open('output.csv', 'a') { |csv| csv << row }
end
```

### Sending Notifications

```ruby
consumer :notify do |event|
  SlackNotifier.send(
    channel: '#alerts',
    message: "Event: #{event.type}"
  )
end
```

### Collecting Results

```ruby
consumer :collect do |item|
  @mutex.synchronize { @results << item }
end
```

## Stage Parameters

All stage types accept various parameters:

### Common Parameters

```ruby
# Name (required)
producer :my_stage do |output|
  # ...
end

# Threads (for concurrent processing)
processor :transform, threads: 5 do |item, output|
  # 5 threads will process items concurrently
end

# Explicit routing
producer :source, to: :destination do |output|
  # Explicitly route to 'destination' stage
end

# Queue subscription
processor :handler, queues: [:high_priority, :default] do |item, output|
  # Receives items from specific queues
end
```

### Producer-Specific

```ruby
producer :generate, to: [:stage_a, :stage_b] do |output|
  # Fan-out: send to multiple stages
end
```

### Processor-Specific

```ruby
processor :transform,
          threads: 10,           # Concurrent workers
          from: :upstream,       # Explicit source
          to: :downstream do     # Explicit destination
  # ...
end
```

### Consumer-Specific

```ruby
consumer :save,
         processes: 4,           # Use forked processes
         from: [:stage_a, :stage_b] do  # Fan-in: receive from multiple
  # ...
end
```

## Stage Lifecycle

Understanding when stages run:

```
Pipeline.run() called
    ↓
All stages start in parallel
    ↓
Producers execute once
    ↓
Processors loop, waiting for input
    ↓
When all input arrives, processors finish
    ↓
Consumers continue until all upstream complete
    ↓
Pipeline finishes
```

## Practical Example: ETL Pipeline

Let's combine all stage types in a realistic example:

```ruby
class ETLPipeline
  include Minigun::DSL

  pipeline do
    # EXTRACT: Read from source database
    producer :extract do |output|
      LegacyDB.find_each(batch_size: 1000) do |record|
        output << record
      end
    end

    # TRANSFORM: Clean and validate
    processor :clean do |record, output|
      cleaned = {
        id: record[:id],
        name: record[:name]&.strip,
        email: record[:email]&.downcase,
        created_at: parse_date(record[:created])
      }
      output << cleaned if cleaned[:email]
    end

    # TRANSFORM: Enrich with external data
    processor :enrich, threads: 10 do |record, output|
      profile = ExternalAPI.fetch_profile(record[:id])
      output << record.merge(profile: profile)
    end

    # BATCH: Group for efficient insertion
    accumulator :batch, max_size: 500 do |batch, output|
      output << batch
    end

    # LOAD: Write to destination database
    consumer :load, processes: 4 do |batch|
      NewDB.insert_many(batch)
      logger.info("Loaded #{batch.size} records")
    end
  end
end
```

## Key Takeaways

- **Producers** generate data and start the pipeline
- **Processors** transform data in the middle of the pipeline
- **Accumulators** batch multiple items together
- **Consumers** perform final processing at the end
- All stages can be parallelized with `threads:` or `processes:`
- Stages run concurrently, processing items as they arrive

## What's Next?

Now that you understand stages, let's learn how to connect them in different ways using routing.

→ [**Continue to Routing**](04_routing.md)

---

**See Also:**
- [Routing Guide](04_routing.md) - How stages connect together
- [Execution Strategies](06_execution_strategies.md) - Parallel execution options
- [API Reference](09_api_reference.md) - Complete DSL reference
