![Minigun](https://github.com/user-attachments/assets/201793a7-ffb1-474b-bb1d-1e739c028d09)

# Minigun go BRRRRR

Minigun is a high-performance data processing pipeline framework for Ruby.

## Features

- Define multi-stage processing pipelines with a simple, expressive DSL.
- Process data using multiple threads and/or processes for maximum performance.
- Use Copy-On-Write (COW) or IPC forking for efficient parallel processing.
- Direct connections between stages with `from` and `to` options.
- Queue-based routing with selective queue subscriptions.
- Batch accumulation for efficient processing.
- Comprehensive error handling and retry mechanisms.
- Optional MessagePack serialization for faster IPC.
- Data compression for large transfers between processes.
- Smart garbage collection for memory optimization.

In many use cases, Minigun can replace queue systems like Resque, Solid Queue, or Sidekiq.
Minigun itself is run entire in Ruby's memory, and is database and application agnostic.

## TODOs

- [ ] Extract examples to examples folder
- [ ] Add more examples based on real-world use cases
- [ ] Add support for named queues and queue-based routing (already there?)
- [ ] Add `parallel` and `sequential` blocks for defining parallel and sequential stages
- [ ] Add support for custom error handling and retry strategies
- [ ] Add support for custom logging and monitoring
- [ ] Add support for custom thread and process management (?)


## Installation

Add this line to your application's Gemfile:

```ruby
gem 'minigun'
```

## Quick Start

```ruby
require 'minigun'

class MyTask
  include Minigun::DSL

  pipeline do
    producer :generate do
      10.times { |i| emit(i) }
    end

    processor :transform do |number|
      emit(number * 2)
    end

    accumulator :batch do |item|
      @items ||= []
      @items << item

      if @items.size >= 5
        batch = @items.dup
        @items.clear
        emit(batch)
      end
    end

    cow_fork :process_batch do |batch|
      # Process the batch in a forked child process
      batch.each { |item| puts "Processing #{item}" }
    end
  end
end

# Run the task
MyTask.new.run
```

## Core Concepts

### Pipeline Stages

Minigun has unified its stage types into a cohesive system where each specialized stage is a variation of a common processor implementation:

1. **Producer**: Generates data for the pipeline. A producer is a processor without input.
2. **Processor**: Transforms data and passes it to the next stage. It can filter, modify, or route data.
3. **Accumulator**: Collects and batches items before forwarding them in groups.
4. **Consumer**: Consumes data without emitting anything further. A consumer is a processor without output.

#### Fork Variants

For handling batched data processing, two fork implementations are available:

- **cow_fork**: Uses Copy-On-Write fork to efficiently process batches in separate child processes
- **ipc_fork**: Uses IPC-style forking for batch processing with different memory characteristics

These are actually aliases for the consumer stage with specific fork configurations.

### Custom Stage Classes

Minigun allows you to create custom stage classes to encapsulate complex behavior or implement specialized processing patterns. All stages inherit from the base `Stage` class and can override its behavior.

#### Execution Modes

Every stage has a `run_mode` that determines how it executes within the pipeline. There are three execution strategies:

```ruby
:autonomous  # Generates data independently (ProducerStage)
:streaming   # Processes stream of items in worker loop (Stage, ConsumerStage)
:composite   # Manages internal stages (PipelineStage)
```

The `run_mode` method controls critical behaviors like:
- Whether the stage needs an input queue
- Whether it needs an executor for concurrent processing
- How the pipeline routes data to and from the stage
- How the stage participates in disconnection detection

#### Creating Custom Stages

To create a custom stage class, inherit from `Minigun::Stage` and implement the required methods:

```ruby
class CustomStage < Minigun::Stage
  # Define execution mode (default: :streaming)
  def run_mode
    :streaming
  end

  # Define how a single item is processed
  def execute(context, item: nil, input_queue: nil, output_queue: nil)
    # Your custom processing logic
    result = process_item(item)
    output_queue << result if output_queue
  end

  # Optional: Customize the worker loop
  def run_worker_loop(stage_ctx)
    # Custom loop implementation
    # See ProducerStage or ConsumerStage for examples
  end

  # Optional: Customize logging type
  def log_type
    "Custom"
  end
end
```

#### Example: Batch Processor Stage

Here's a custom stage that batches items with a timeout:

```ruby
class TimedBatchStage < Minigun::Stage
  attr_reader :batch_size, :timeout

  def initialize(name:, options: {})
    super
    @batch_size = options[:batch_size] || 100
    @timeout = options[:timeout] || 5.0
  end

  def run_mode
    :streaming  # Processes items from input queue
  end

  def run_worker_loop(stage_ctx)
    require 'minigun/queue_wrappers'

    wrapped_input = Minigun::InputQueue.new(
      stage_ctx.input_queue,
      stage_ctx.stage_name,
      stage_ctx.sources_expected
    )

    wrapped_output = Minigun::OutputQueue.new(
      stage_ctx.stage_name,
      stage_ctx.dag.downstream(stage_ctx.stage_name).map { |ds|
        stage_ctx.stage_input_queues[ds]
      },
      stage_ctx.stage_input_queues,
      stage_ctx.runtime_edges
    )

    batch = []
    last_flush = Time.now

    loop do
      # Check for timeout
      if !batch.empty? && (Time.now - last_flush) >= @timeout
        wrapped_output << batch.dup
        batch.clear
        last_flush = Time.now
      end

      # Try to get item with timeout
      begin
        item = wrapped_input.pop(timeout: 0.1)

        if item == Minigun::AllUpstreamsDone
          # Flush remaining items
          wrapped_output << batch unless batch.empty?
          break
        end

        batch << item

        # Flush if batch is full
        if batch.size >= @batch_size
          wrapped_output << batch.dup
          batch.clear
          last_flush = Time.now
        end
      rescue ThreadError
        # Timeout, continue to check for flush
      end
    end

    send_end_signals(stage_ctx)
  end
end

# Use in a pipeline
class MyTask
  include Minigun::DSL

  pipeline do
    producer :generate do
      100.times { |i| emit(i) }
    end

    # Use custom stage class
    custom_stage TimedBatchStage, :batch, batch_size: 10, timeout: 2.0

    consumer :process do |batch, output|
      puts "Processing batch of #{batch.size} items"
    end
  end
end
```

#### Example: Stateful Filter Stage

Create a stage that filters based on accumulated state:

```ruby
class DeduplicatorStage < Minigun::Stage
  def initialize(name:, options: {})
    super
    @seen = Set.new
    @mutex = Mutex.new
  end

  def run_mode
    :streaming
  end

  def execute(context, item: nil, input_queue: nil, output_queue: nil)
    key = extract_key(item)

    is_new = @mutex.synchronize do
      if @seen.include?(key)
        false
      else
        @seen.add(key)
        true
      end
    end

    output_queue << item if is_new && output_queue
  end

  private

  def extract_key(item)
    # Override in subclass or pass as option
    item[:id] || item
  end
end
```

#### When to Create Custom Stages

Consider creating custom stage classes when you need:

1. **Complex State Management**: Stages that maintain sophisticated internal state
2. **Specialized Worker Loops**: Custom timing, batching, or control flow logic
3. **Reusable Patterns**: Behavior you want to use across multiple pipelines
4. **Framework Extensions**: Adding new execution modes or patterns to Minigun
5. **Performance Optimization**: Fine-tuned control over threading, batching, or memory

For simple transformations, use the standard `producer`, `processor`, and `consumer` DSL methods. For complex, reusable behavior, create custom stage classes.

### Stage Connections

Minigun supports two types of stage connections:

1. **Sequential Connections**: By default, stages are connected in the order they're defined
2. **Explicit Connections**: Use `from` and `to` options to explicitly define connections

```ruby
# Sequential connection
processor :first_stage do |item|
  item + 1
end

processor :second_stage do |item|
  item * 2
end

# Explicit connections
processor :stage_a, to: [:stage_b, :stage_c] do |item|
  item
end

processor :stage_b, from: :stage_a do |item|
  # Process items from stage_a
end

processor :stage_c, from: :stage_a do |item|
  # Also process items from stage_a
end
```

### Advanced Connection Examples

#### Branching Pipeline

Create a pipeline that branches based on the type of data:

```ruby
pipeline do
  # Producer emits to multiple processors
  producer :user_producer, to: [:email_processor, :notification_processor] do
    User.find_each do |user|
      emit(user)
    end
  end

  # These processors receive data from the same producer
  processor :email_processor, from: :user_producer do |user|
    generate_email(user)
  end

  processor :notification_processor, from: :user_producer do |user|
    generate_notification(user)
  end

  # Connect the email processor to an accumulator
  accumulator :email_accumulator, from: :email_processor do |email|
    @emails ||= []
    @emails << email

    if @emails.size >= 100
      batch = @emails.dup
      @emails.clear
      emit(batch)
    end
  end

  # Process accumulated emails
  cow_fork :email_sender, from: :email_accumulator, processes: 4 do |emails|
    emails.each { |email| send_email(email) }
  end

  # Process notifications directly
  consumer :notification_sender, from: :notification_processor do |notification|
    send_notification(notification)
  end
end
```

#### Diamond-Shaped Pipeline

Create a pipeline that splits and rejoins:

```ruby
pipeline do
  producer :data_source do
    data_items.each { |item| emit(item) }
  end

  # Split to parallel processors
  processor :validate, from: :data_source, to: [:transform_a, :transform_b] do |item|
    emit(item) if item.valid?
  end

  # Parallel transformations
  processor :transform_a, from: :validate, to: :combine do |item|
    emit(transform_a(item))
  end

  processor :transform_b, from: :validate, to: :combine do |item|
    emit(transform_b(item))
  end

  # Rejoin for final processing
  processor :combine, from: [:transform_a, :transform_b] do |item|
    @results ||= []
    @results << item

    if @results.size >= 2
      emit(combine_results(@results))
      @results.clear
    end
  end

  consumer :store_results, from: :combine do |result|
    store_result(result)
  end
end
```

### Queue-Based Routing

You can route items to specific stages by subscribing to named queues:

```ruby
processor :route, to: [:high_priority, :low_priority] do |item|
  if item[:priority] == :high
    emit_to_queue(:high_priority, item)
  else
    emit_to_queue(:low_priority, item)
  end
end

processor :high_priority, queues: [:high_priority] do |item|
  # Process high priority items
end

processor :low_priority, queues: [:low_priority] do |item|
  # Process low priority items
end
```

### Advanced Queue Examples

#### Priority Processing

Create a pipeline with priority lanes for VIP users:

```ruby
pipeline do
  producer :user_producer do
    User.find_each do |user|
      emit(user)

      # Route VIP users to a high priority queue
      emit_to_queue(:high_priority, user) if user.vip?
    end
  end

  # This processor handles both default and high priority users
  processor :email_processor, threads: 5, queues: [:default, :high_priority] do |user|
    email = generate_email(user)
    emit(email)
  end

  # Regular handling for emails
  accumulator :email_accumulator, from: :email_processor do |email|
    @emails ||= {}
    @emails[email.type] ||= []
    @emails[email.type] << email

    # Emit batches by email type when they reach the threshold
    @emails.each do |type, batch|
      if batch.size >= 50
        emit_to_queue(type, batch.dup)
        batch.clear
      end
    end
  end

  # Handle newsletter emails separately
  consumer :newsletter_sender, queues: [:newsletter] do |emails|
    send_newsletter_batch(emails)
  end

  # Handle transaction emails separately
  consumer :transaction_sender, queues: [:transaction] do |emails|
    send_transaction_batch(emails)
  end

  # Handle all other types
  consumer :general_sender, queues: [:default] do |emails|
    send_email_batch(emails)
  end
end
```

#### Load Balancing

Distribute work across multiple queues for better load balancing:

```ruby
pipeline do
  producer :data_source do
    large_dataset.each_with_index do |item, i|
      # Round-robin distribute across multiple queues
      queue = [:queue_1, :queue_2, :queue_3][i % 3]
      emit_to_queue(queue, item)
    end
  end

  # Process queue 1 with specific settings
  processor :worker_1, queues: [:queue_1], threads: 3 do |item|
    process_with_worker_1(item)
  end

  # Process queue 2 with different settings
  processor :worker_2, queues: [:queue_2], threads: 5 do |item|
    process_with_worker_2(item)
  end

  # Process queue 3 with yet different settings
  processor :worker_3, queues: [:queue_3], threads: 2 do |item|
    process_with_worker_3(item)
  end

  # All results go to the same accumulator
  accumulator :result_collector, from: [:worker_1, :worker_2, :worker_3] do |result|
    @results ||= []
    @results << result

    if @results.size >= 100
      batch = @results.dup
      @results.clear
      emit(batch)
    end
  end

  consumer :store_results, from: :result_collector do |batch|
    store_batch(batch)
  end
end
```

## Configuration Options

```ruby
class ConfiguredTask
  include Minigun::Task

  # Global configuration
  max_threads 10        # Maximum threads per process
  max_processes 4       # Maximum forked processes
  max_retries 3         # Maximum retry attempts for errors
  batch_size 100        # Default batch size
  consumer_type :cow    # Default consumer fork implementation (:cow or :ipc)

  # Advanced IPC options
  pipe_timeout 30       # Timeout for IPC pipe operations (seconds)
  use_compression true  # Enable compression for large IPC transfers
  gc_probability 0.1    # Probability of GC during batch processing (0.0-1.0)

  # Stage-specific configuration
  pipeline do
    producer :source do
      # Generate data
    end

    processor :transform, threads: 5 do |item|
      # Process with 5 threads
    end

    accumulator :batch, max_queue: 1000, max_all: 2000 do |item|
      # Batch with custom limits
    end

    consumer :sink, fork: :ipc, processes: 2 do |batch|
      # Consume with 2 IPC processes
    end
  end
end
```

### Queue Sizing and Backpressure

Minigun uses `SizedQueue` (bounded queues) by default for automatic backpressure. This prevents memory bloat when producers are faster than consumers.

**Global Default:**

```ruby
# Set global default queue size
Minigun.configure do |config|
  config.default_queue_size = 1000  # Default is 1000
end
```

**Per-Stage Queue Size:**

```ruby
pipeline do
  producer :fast_source do |output|
    # Produces data very quickly
  end

  # Small queue for tight backpressure
  processor :slow_transform, queue_size: 50 do |item, output|
    # Slow processing creates backpressure on producer
    sleep 0.1
    output << item * 2
  end

  # Large queue for buffering bursts
  consumer :batch_sink, queue_size: 5000 do |item, output|
    # Can handle bursty workloads
  end

  # Unbounded queue (use with caution!)
  consumer :emergency_overflow, queue_size: Float::INFINITY do |item, output|
    # No backpressure - can grow without bound
  end
end
```

**Unbounded Queues:**

Set `queue_size` to `0`, `nil`, or `Float::INFINITY` for unbounded `Queue` instead of `SizedQueue`:

```ruby
# All three are equivalent
processor :stage1, queue_size: 0
processor :stage2, queue_size: nil
processor :stage3, queue_size: Float::INFINITY
```

**When to Use Each:**

- **Bounded (default 1000)**: Best for most cases. Provides automatic backpressure.
- **Small (50-100)**: Tight coupling between stages, immediate backpressure.
- **Large (5000+)**: Buffer for bursty producers, smooth out spikes.
- **Unbounded**: Only when you're certain producers won't overwhelm consumers (e.g., rate-limited APIs).

## Hooks

Minigun supports hooks for various lifecycle events:

```ruby
class TaskWithHooks
  include Minigun::Task

  before_run do
    # Called before the pipeline starts
  end

  after_run do
    # Called after the pipeline completes
  end

  before_fork do
    # Called in the parent process before forking
  end

  after_fork do
    # Called in the child process after forking
  end
end
```

## Example Use Cases

### Data ETL Pipeline

```ruby
class DataETL
  include Minigun::Task

  pipeline do
    producer :extract do
      # Extract data from source
      database.each_batch(1000) do |batch|
        emit(batch)
      end
    end

    processor :transform do |batch|
      # Transform the data
      batch.map { |row| transform_row(row) }
    end

    consumer :load do |batch|
      # Load data to destination
      destination.insert_batch(batch)
    end
  end
end
```

### Parallel Web Crawler

```ruby
class WebCrawler
  include Minigun::Task

  max_threads 20

  pipeline do
    producer :seed_urls do
      initial_urls.each { |url| emit(url) }
    end

    processor :fetch_pages do |url|
      response = HTTP.get(url)
      { url: url, content: response.body }
    end

    processor :extract_links do |page|
      links = extract_links_from_html(page[:content])
      # Emit new links for crawling
      links.each { |link| emit(link) }
      # Pass the page content for processing
      page
    end

    accumulator :batch_pages do |page|
      @pages ||= []
      @pages << page

      if @pages.size >= 10
        batch = @pages.dup
        @pages.clear
        emit(batch)
      end
    end

    cow_fork :process_pages do |batch|
      # Process pages in parallel using forked processes
      batch.each { |page| process_content(page) }
    end
  end
end
```

## License

The gem is available as open source under the terms of the [MIT License](LICENSE).

## Fork Implementation Options

Minigun provides two different fork implementations for processing data in separate processes:

### COW Fork (Copy-On-Write)

```ruby
cow_fork :process_batch do |batch|
  # Process items in a child process with copy-on-write memory sharing
  process_items(batch)
end
```

The COW fork implementation leverages Ruby's copy-on-write memory sharing between parent and child processes. With COW fork:

- Memory pages are shared between parent and child until modified
- No serialization overhead for passing data between processes
- Ideal for read-only operations on large data structures
- Best performance when memory footprint is important

### IPC Fork

```ruby
ipc_fork :process_batch do |batch|
  # Process items in a child process with explicit IPC communication
  process_items(batch)
end
```

The IPC fork implementation uses explicit interprocess communication:

- Data is serialized and passed through pipes between parent and child
- Provides process isolation with explicit memory boundaries
- Supports optimizations like MessagePack and compression
- Better when child processes significantly modify data

#### IPC Fork Optimizations

##### MessagePack Serialization

For better performance, install the MessagePack gem to automatically improve serialization speed:

```ruby
# Add to your Gemfile
gem 'msgpack'
```

When MessagePack is available, Minigun automatically uses it for IPC communication instead of Ruby's Marshal, providing:
- Faster serialization/deserialization
- Smaller data size
- Better cross-language compatibility

##### Compression

By default, Minigun will compress large data transfers between processes:

```ruby
# Configure compression settings
ipc_fork :process_batch, use_compression: true do |batch|
  process_items(batch)
end
```

- Automatically compresses data when beneficial (>1KB and compression reduces size)
- Uses Zlib for compression
- Can be disabled with `use_compression: false`

##### Garbage Collection Optimization

Minigun optimizes garbage collection in forked processes:

- Performs GC before forking to minimize unnecessary memory duplication
- Periodic GC during batch processing to prevent memory bloat
- Configurable GC probability with `gc_probability` option

##### Additional IPC Options

```ruby
ipc_fork :process_batch,
         pipe_timeout: 60,         # Timeout for pipe operations (seconds)
         max_chunk_size: 2_000_000 # Max size for chunked data (bytes)
         do |batch|
  process_items(batch)
end
```
