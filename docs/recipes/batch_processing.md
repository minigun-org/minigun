# Recipe: Batch Processing

Process large datasets efficiently by batching items and using parallel execution.

## Problem

You have millions of records to process. Processing them one-by-one is too slow, but you can't load everything into memory. You need to stream, batch, and parallelize.

## Solution

```ruby
require 'minigun'

class BatchProcessor
  include Minigun::DSL

  attr_accessor :total_processed, :total_failed

  def initialize(batch_size: 1000, workers: 4)
    @batch_size = batch_size
    @workers = workers
    @total_processed = Concurrent::AtomicFixnum.new(0)
    @total_failed = Concurrent::AtomicFixnum.new(0)
    @start_time = Time.now
  end

  pipeline do
    # Stream records from database (doesn't load all into memory)
    producer :stream_records do |output|
      Record.find_each(batch_size: 1000) do |record|
        output << record
      end
    end

    # Filter out already-processed records
    processor :filter_processed, threads: 5 do |record, output|
      unless ProcessedRecords.exists?(record.id)
        output << record
      end
    end

    # Enrich with external data (I/O-bound, high concurrency)
    processor :enrich, threads: 20 do |record, output|
      begin
        enriched = record.to_h.merge(
          external_data: ExternalAPI.fetch(record.id)
        )
        output << enriched
      rescue ExternalAPI::Error => e
        logger.error("Enrichment failed for #{record.id}: #{e.message}")
        output << record.to_h  # Continue without enrichment
      end
    end

    # Transform data (CPU-bound, use processes)
    processor :transform, execution: :cow_fork, max: 8 do |data, output|
      transformed = {
        id: data[:id],
        processed_at: Time.now,
        result: expensive_computation(data)
      }
      output << transformed
    end

    # Batch for efficient database writes
    accumulator :batch, max_size: @batch_size do |batch, output|
      output << batch
    end

    # Write batches to database (parallel workers)
    consumer :save, threads: @workers do |batch|
      begin
        ProcessedRecord.transaction do
          ProcessedRecord.insert_all(batch)
          ProcessedRecords.insert_all(batch.map { |b| { id: b[:id] } })
        end

        @total_processed.increment(batch.size)
        report_progress
      rescue => e
        @total_failed.increment(batch.size)
        logger.error("Failed to save batch: #{e.message}")
        save_to_dead_letter_queue(batch)
      end
    end
  end

  private

  def expensive_computation(data)
    # Simulate CPU-intensive work
    result = data[:value] * Math.sqrt(data[:value])
    sleep 0.01  # Simulate work
    result
  end

  def report_progress
    count = @total_processed.value
    return unless count % 10_000 == 0

    elapsed = Time.now - @start_time
    rate = count / elapsed

    puts "[#{Time.now}] Processed: #{count.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse} " \
         "(#{rate.round(2)}/s, #{elapsed.round(0)}s elapsed)"
  end

  def save_to_dead_letter_queue(batch)
    File.open('failed_batches.jsonl', 'a') do |f|
      f.puts({ timestamp: Time.now, batch: batch }.to_json)
    end
  end

  def logger
    @logger ||= Logger.new(STDOUT)
  end
end

# Run the processor
processor = BatchProcessor.new(
  batch_size: 500,
  workers: 4
)

result = processor.run

puts "\n=== Processing Complete ==="
puts "Total processed: #{processor.total_processed.value.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse}"
puts "Total failed: #{processor.total_failed.value}"
puts "Duration: #{result[:duration].round(2)}s"
puts "Average rate: #{(processor.total_processed.value / result[:duration]).round(2)} records/s"
```

## How It Works

### Streaming

```ruby
producer :stream_records do |output|
  Record.find_each(batch_size: 1000) do |record|
    output << record
  end
end
```

- `find_each` streams records in batches
- Doesn't load entire dataset into memory
- Processes as it fetches

### Filtering

```ruby
processor :filter_processed, threads: 5 do |record, output|
  unless ProcessedRecords.exists?(record.id)
    output << record
  end
end
```

- Skip already-processed records
- Uses threads for parallel database lookups
- Prevents duplicate processing

### Parallel Enrichment

```ruby
processor :enrich, threads: 20 do |record, output|
  enriched = record.to_h.merge(
    external_data: ExternalAPI.fetch(record.id)
  )
  output << enriched
end
```

- High concurrency (20 threads) for I/O-bound API calls
- Graceful degradation on errors
- Continues without enrichment if API fails

### CPU-Intensive Transform

```ruby
processor :transform, execution: :cow_fork, max: 8 do |data, output|
  transformed = expensive_computation(data)
  output << transformed
end
```

- Uses COW fork for true parallelism
- 8 processes for CPU-bound work
- No GVL limitations

### Batching

```ruby
accumulator :batch, max_size: 500 do |batch, output|
  output << batch
end
```

- Groups 500 items into batches
- Reduces database roundtrips
- More efficient bulk inserts

### Parallel Writes

```ruby
consumer :save, threads: 4 do |batch|
  ProcessedRecord.transaction do
    ProcessedRecord.insert_all(batch)
  end
end
```

- 4 threads for parallel database writes
- Transactions for atomicity
- Error handling with dead letter queue

## Variations

### Process Files in Directory

```ruby
producer :files do |output|
  Dir['data/**/*.csv'].each do |filepath|
    output << filepath
  end
end

processor :read_file, threads: 10 do |filepath, output|
  CSV.foreach(filepath, headers: true) do |row|
    output << row.to_h
  end
end
```

### Chunk Large Files

```ruby
producer :chunk_file do |output|
  File.open('huge_file.txt').each_slice(1000) do |lines|
    output << lines
  end
end

processor :process_chunk, threads: 8 do |lines, output|
  lines.each do |line|
    output << process_line(line)
  end
end
```

### Process S3 Objects

```ruby
producer :s3_objects do |output|
  s3.list_objects(bucket: 'my-bucket').each do |object|
    output << object.key
  end
end

processor :download_and_process, threads: 20 do |key, output|
  content = s3.get_object(bucket: 'my-bucket', key: key).body.read
  output << parse_and_transform(content)
end
```

### Split by Priority

```ruby
processor :route_by_priority, to: [:high, :normal, :low] do |record, output|
  case record[:priority]
  when 'high'
    output.to(:high) << record
  when 'normal'
    output.to(:normal) << record
  else
    output.to(:low) << record
  end
end

# High priority: more workers, smaller batches (faster feedback)
accumulator :high_batch, from: :route_by_priority, max_size: 100 do |batch, output|
  output << { priority: :high, batch: batch }
end

consumer :high_processor, threads: 10 do |data|
  process_urgently(data[:batch])
end

# Normal priority: balanced
accumulator :normal_batch, from: :route_by_priority, max_size: 500 do |batch, output|
  output << { priority: :normal, batch: batch }
end

consumer :normal_processor, threads: 4 do |data|
  process_normally(data[:batch])
end

# Low priority: larger batches, fewer workers
accumulator :low_batch, from: :route_by_priority, max_size: 2000 do |batch, output|
  output << { priority: :low, batch: batch }
end

consumer :low_processor, threads: 2 do |data|
  process_when_available(data[:batch])
end
```

## Memory Management

### Limit In-Flight Items

```ruby
# Smaller queues = less memory, more backpressure
processor :heavy_stage, queue_size: 100 do |item, output|
  # Only 100 items buffered at a time
end
```

### Stream vs Load

```ruby
# ❌ Bad: Loads everything into memory
producer :all_at_once do |output|
  Record.all.each { |record| output << record }
end

# ✅ Good: Streams in batches
producer :streaming do |output|
  Record.find_each(batch_size: 1000) { |record| output << record }
end
```

### Clear Large Objects

```ruby
processor :process do |large_data, output|
  result = transform(large_data)
  large_data = nil  # Clear reference
  GC.start if rand < 0.01  # Occasional GC

  output << result
end
```

## Performance Optimization

### Use HUD to Find Bottlenecks

```ruby
require 'minigun/hud'

Minigun::HUD.run_with_hud(BatchProcessor.new)
```

The HUD shows:
- Which stage is slowest (bottleneck)
- Throughput for each stage
- Latency percentiles

### Tune Based on Workload

```ruby
# I/O-bound (database, API, files)
processor :io_work, threads: 50 do |item, output|
  # High concurrency for I/O
end

# CPU-bound (computation)
processor :cpu_work, execution: :cow_fork, max: 8 do |item, output|
  # True parallelism with processes
end

# Mixed
processor :mixed_work, threads: 10 do |item, output|
  # Moderate threading
end
```

### Adjust Batch Sizes

```ruby
# Small batches: Faster feedback, more overhead
accumulator :small, max_size: 50

# Large batches: Less overhead, slower feedback
accumulator :large, max_size: 5000

# Test and measure!
```

## Error Handling

### Retry Individual Items

```ruby
consumer :save_with_retry do |batch|
  batch.each do |item|
    retries = 0
    begin
      database.insert(item)
    rescue DatabaseError => e
      retries += 1
      if retries < 3
        sleep 2 ** retries
        retry
      else
        @failed << item
      end
    end
  end
end
```

### Partial Batch Success

```ruby
consumer :partial_save do |batch|
  successful = []
  failed = []

  batch.each do |item|
    begin
      database.insert(item)
      successful << item
    rescue => e
      failed << { item: item, error: e.message }
    end
  end

  @total_success += successful.size
  @total_failed += failed.size

  save_failures(failed) unless failed.empty?
end
```

### Circuit Breaker

```ruby
processor :with_circuit_breaker, threads: 10 do |item, output|
  @failures ||= Concurrent::AtomicFixnum.new(0)
  @circuit_open ||= Concurrent::AtomicBoolean.new(false)

  if @circuit_open.value
    @failed << item
    next
  end

  begin
    result = external_service.call(item)
    @failures.value = 0  # Reset on success
    output << result
  rescue ServiceError => e
    failures = @failures.increment

    if failures >= 10
      @circuit_open.value = true
      logger.error("Circuit breaker opened after #{failures} failures")
    end

    @failed << item
  end
end
```

## Monitoring

### Progress Bar

```ruby
require 'ruby-progressbar'

producer :with_progress do |output|
  total = Record.count
  progress = ProgressBar.create(
    title: "Processing",
    total: total,
    format: "%t: |%B| %p%% %e"
  )

  Record.find_each do |record|
    output << record
    progress.increment
  end
end
```

### Periodic Stats

```ruby
processor :stats do |item, output|
  @count ||= 0
  @start ||= Time.now

  @count += 1

  if @count % 1000 == 0
    elapsed = Time.now - @start
    rate = @count / elapsed

    puts "Processed: #{@count} (#{rate.round(2)}/s)"
  end

  output << item
end
```

### Export Metrics

```ruby
def finalize
  metrics = {
    processed: @total_processed.value,
    failed: @total_failed.value,
    duration: Time.now - @start_time,
    rate: @total_processed.value / (Time.now - @start_time)
  }

  File.write('metrics.json', metrics.to_json)
end
```

## Testing

### Test with Sample Data

```ruby
RSpec.describe BatchProcessor do
  it 'processes records in batches' do
    # Create sample data
    10.times { |i| Record.create!(value: i) }

    processor = BatchProcessor.new(batch_size: 5)
    processor.run

    expect(processor.total_processed.value).to eq(10)
    expect(ProcessedRecord.count).to eq(10)
  end
end
```

### Mock External Dependencies

```ruby
it 'handles API failures gracefully' do
  allow(ExternalAPI).to receive(:fetch).and_raise(ExternalAPI::Error)

  processor = BatchProcessor.new
  expect { processor.run }.not_to raise_error
end
```

## Key Takeaways

- **Stream data** instead of loading everything
- **Batch writes** for database efficiency
- **Parallel processing** at each stage (threads for I/O, forks for CPU)
- **Bounded queues** prevent memory exhaustion
- **Monitor progress** with HUD or custom logging
- **Handle errors** gracefully with retries and dead letter queues
- **Test with samples** before running on full dataset

## See Also

- [ETL Pipeline Recipe](etl_pipeline.md) - Extract, transform, load patterns
- [Performance Tuning](11_performance_tuning.md) - Optimization strategies
- [Execution Strategies](../guides/06_execution_strategies.md) - Threads vs forks
- [Example: Large Dataset](../../examples/14_large_dataset.rb) - Working example
