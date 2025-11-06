# Recipe: ETL Pipeline

Extract data from a source, transform it, and load it into a destination.

## Problem

You need to move data from a legacy database to a new system, applying transformations and validations along the way.

## Solution

```ruby
require 'minigun'

class ETLPipeline
  include Minigun::DSL

  attr_accessor :processed_count, :failed_count

  def initialize
    @processed_count = 0
    @failed_count = 0
    @mutex = Mutex.new
  end

  pipeline do
    # EXTRACT: Read from source database
    producer :extract do |output|
      LegacyDatabase.find_each(batch_size: 1000) do |record|
        output << record
      end
    end

    # TRANSFORM: Clean and validate data
    processor :clean, threads: 5 do |record, output|
      begin
        cleaned = {
          id: record[:id],
          name: record[:name]&.strip&.titleize,
          email: record[:email]&.downcase,
          phone: normalize_phone(record[:phone]),
          created_at: parse_date(record[:created])
        }

        # Validate required fields
        if cleaned[:email] && cleaned[:email].include?('@')
          output << cleaned
        else
          @mutex.synchronize { @failed_count += 1 }
          logger.warn("Invalid record: #{record[:id]}")
        end
      rescue => e
        @mutex.synchronize { @failed_count += 1 }
        logger.error("Error processing record #{record[:id]}: #{e.message}")
      end
    end

    # TRANSFORM: Enrich with external data
    processor :enrich, threads: 10 do |record, output|
      begin
        # Fetch additional data from API
        profile = ExternalAPI.fetch_profile(record[:id])
        enriched = record.merge(
          profile: profile,
          enriched_at: Time.now
        )
        output << enriched
      rescue ExternalAPI::NotFound
        # Skip enrichment if not found
        output << record
      rescue => e
        logger.error("Enrichment failed for #{record[:id]}: #{e.message}")
        output << record
      end
    end

    # BATCH: Group for efficient insertion
    accumulator :batch, max_size: 500 do |batch, output|
      output << batch
    end

    # LOAD: Write to destination database
    consumer :load, threads: 4 do |batch|
      begin
        NewDatabase.transaction do
          NewDatabase.insert_all(batch)
        end

        @mutex.synchronize { @processed_count += batch.size }
        logger.info("Loaded #{batch.size} records (total: #{@processed_count})")
      rescue => e
        @mutex.synchronize { @failed_count += batch.size }
        logger.error("Failed to load batch: #{e.message}")
      end
    end
  end

  private

  def normalize_phone(phone)
    return nil unless phone
    phone.gsub(/\D/, '')  # Remove non-digits
  end

  def parse_date(date_string)
    return nil unless date_string
    Time.parse(date_string)
  rescue
    nil
  end

  def logger
    @logger ||= Logger.new(STDOUT)
  end
end

# Run the pipeline
etl = ETLPipeline.new
result = etl.run

puts "\n=== ETL Complete ==="
puts "Processed: #{etl.processed_count}"
puts "Failed: #{etl.failed_count}"
puts "Duration: #{result[:duration].round(2)}s"
puts "Throughput: #{(etl.processed_count / result[:duration]).round(2)} records/s"
```

## How It Works

### Extract Phase

```ruby
producer :extract do |output|
  LegacyDatabase.find_each(batch_size: 1000) do |record|
    output << record
  end
end
```

- Uses `find_each` to stream records (doesn't load all into memory)
- Batch size of 1000 balances memory and database efficiency
- Emits one record at a time to the pipeline

### Transform Phase

**Cleaning:**
```ruby
processor :clean, threads: 5 do |record, output|
  # Normalize data format
  # Validate required fields
  # Filter invalid records
end
```

- 5 threads for parallel processing
- Validates and normalizes data
- Filters out invalid records (doesn't emit them)
- Counts failures for reporting

**Enrichment:**
```ruby
processor :enrich, threads: 10 do |record, output|
  # Fetch external data
  # Merge with record
  # Handle failures gracefully
end
```

- 10 threads for high-concurrency API calls
- Graceful degradation (continues without enrichment if API fails)
- Preserves original record if enrichment unavailable

### Batching

```ruby
accumulator :batch, max_size: 500 do |batch, output|
  output << batch
end
```

- Groups 500 records into batches
- Enables efficient bulk inserts
- Reduces database roundtrips

### Load Phase

```ruby
consumer :load, threads: 4 do |batch|
  NewDatabase.transaction do
    NewDatabase.insert_all(batch)
  end
end
```

- 4 threads for parallel writes
- Uses transactions for atomicity
- Tracks progress with counters

## Variations

### Add Data Validation

```ruby
processor :validate do |record, output|
  validator = RecordValidator.new(record)

  if validator.valid?
    output << record
  else
    @failed_records << { record: record, errors: validator.errors }
  end
end
```

### Handle Duplicate Records

```ruby
processor :deduplicate do |record, output|
  @seen_ids ||= Set.new

  if @seen_ids.add?(record[:id])
    output << record  # New record
  else
    logger.warn("Duplicate record: #{record[:id]}")
  end
end
```

### Add Progress Reporting

```ruby
processor :report_progress do |record, output|
  @count ||= 0
  @mutex.synchronize do
    @count += 1
    puts "Processed #{@count} records" if @count % 1000 == 0
  end
  output << record
end
```

### Split Load by Type

```ruby
processor :route_by_type, to: [:users_loader, :companies_loader] do |record, output|
  if record[:type] == 'user'
    output.to(:users_loader) << record
  else
    output.to(:companies_loader) << record
  end
end

consumer :users_loader do |record|
  UsersTable.insert(record)
end

consumer :companies_loader do |record|
  CompaniesTable.insert(record)
end
```

## Performance Tuning

### Find the Bottleneck

Use the HUD to identify slow stages:

```ruby
require 'minigun/hud'

Minigun::HUD.run_with_hud(ETLPipeline)
```

### Tune Thread Counts

```ruby
# If enrich is the bottleneck:
processor :enrich, threads: 50 do |record, output|
  # Increase concurrency for I/O-bound work
end

# If load is the bottleneck:
consumer :load, threads: 10 do |batch|
  # More parallel database connections
end
```

### Adjust Batch Size

```ruby
# Smaller batches (faster feedback, more roundtrips)
accumulator :batch, max_size: 100

# Larger batches (fewer roundtrips, less frequent updates)
accumulator :batch, max_size: 2000
```

### Use Fork for CPU-Intensive Transform

```ruby
# If transformation is CPU-heavy:
processor :heavy_transform, execution: :cow_fork, max: 8 do |record, output|
  output << expensive_computation(record)
end
```

## Error Handling

### Retry Failed Records

```ruby
consumer :load do |batch|
  retries = 0
  begin
    NewDatabase.insert_all(batch)
  rescue DatabaseError => e
    retries += 1
    if retries < 3
      sleep 2 ** retries  # Exponential backoff
      retry
    else
      @failed_batches << batch
      logger.error("Failed batch after #{retries} retries")
    end
  end
end
```

### Dead Letter Queue

```ruby
processor :validate do |record, output|
  if valid?(record)
    output << record
  else
    @dead_letter_queue << record
  end
end

# After pipeline completes:
File.write('failed_records.json', @dead_letter_queue.to_json)
```

## Monitoring

### Track Progress

```ruby
def initialize
  @start_time = Time.now
  @processed = 0
  @mutex = Mutex.new
end

consumer :load do |batch|
  @mutex.synchronize do
    @processed += batch.size
    elapsed = Time.now - @start_time
    rate = @processed / elapsed
    puts "Progress: #{@processed} records (#{rate.round(2)}/s)"
  end
end
```

### Final Statistics

```ruby
result = etl.run

puts "\n=== Statistics ==="
puts "Total processed: #{etl.processed_count}"
puts "Total failed: #{etl.failed_count}"
puts "Success rate: #{((etl.processed_count.to_f / (etl.processed_count + etl.failed_count)) * 100).round(2)}%"
puts "Duration: #{result[:duration].round(2)}s"
puts "Throughput: #{(etl.processed_count / result[:duration]).round(2)} records/s"
puts "Bottleneck: #{result[:stats].bottleneck.stage_name}"
```

## Testing

### Test Individual Stages

```ruby
RSpec.describe ETLPipeline do
  it 'cleans data correctly' do
    pipeline = ETLPipeline.new

    # Test the clean processor logic in isolation
    input = { name: '  john doe  ', email: 'JOHN@EXAMPLE.COM' }
    cleaned = pipeline.send(:clean_record, input)

    expect(cleaned[:name]).to eq('John Doe')
    expect(cleaned[:email]).to eq('john@example.com')
  end
end
```

### Test with Sample Data

```ruby
it 'processes sample data' do
  # Mock the database
  allow(LegacyDatabase).to receive(:find_each).and_yield(sample_record)

  pipeline = ETLPipeline.new
  pipeline.run

  expect(pipeline.processed_count).to eq(1)
end
```

## Key Takeaways

- **Extract** streams data efficiently (don't load all into memory)
- **Transform** parallelizes with threads (clean, validate, enrich)
- **Batch** groups items for efficient bulk operations
- **Load** uses transactions for data integrity
- **Monitor** with HUD to find and fix bottlenecks
- **Handle errors** gracefully and track failures

## See Also

- [Batch Processing Recipe](batch_processing.md) - Processing large datasets
- [Error Handling Guide](../guides/error_handling.md) - Retry strategies
- [Performance Tuning](../advanced/performance_tuning.md) - Optimization techniques
- [Example: Simple ETL](../../examples/15_simple_etl.rb) - Working example
