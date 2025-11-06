# DSL API Reference

Complete reference for the Minigun DSL (Domain-Specific Language).

## Overview

The DSL provides methods for defining pipelines and stages. Include `Minigun::DSL` in your class to access these methods.

```ruby
class MyPipeline
  include Minigun::DSL

  pipeline do
    # DSL methods available here
  end
end
```

## Pipeline Definition

### `pipeline(&block)`

Defines a pipeline with stages.

**Example:**
```ruby
pipeline do
  producer :generate do |output|
    10.times { |i| output << i }
  end

  processor :transform do |item, output|
    output << (item * 2)
  end

  consumer :collect do |item|
    puts item
  end
end
```

### `nested_pipeline(pipeline_class, name, options = {})`

Embeds another pipeline as a stage.

**Parameters:**
- `pipeline_class` - Class that includes Minigun::DSL
- `name` - Symbol name for the nested pipeline stage
- `options` - Hash of options (same as stage options)

**Example:**
```ruby
class SubPipeline
  include Minigun::DSL

  pipeline do
    processor :step1 { |item, output| output << transform(item) }
    processor :step2 { |item, output| output << validate(item) }
  end
end

class MainPipeline
  include Minigun::DSL

  pipeline do
    producer :source { generate_data }
    nested_pipeline SubPipeline, :process
    consumer :save { |item| save(item) }
  end
end
```

## Stage Definitions

### `producer(name, options = {}, &block)`

Defines a stage that generates data (no input, only output).

**Parameters:**
- `name` - Symbol stage name
- `options` - Hash of options (see [Stage Options](#stage-options))
- `block` - Block with one parameter: `output`

**Example:**
```ruby
producer :generate do |output|
  100.times { |i| output << i }
end

producer :fetch_users, threads: 5 do |output|
  User.find_each { |user| output << user }
end
```

### `processor(name, options = {}, &block)`

Defines a stage that transforms data (has input and output).

**Parameters:**
- `name` - Symbol stage name
- `options` - Hash of options (see [Stage Options](#stage-options))
- `block` - Block with two parameters: `item, output`

**Example:**
```ruby
processor :double do |number, output|
  output << (number * 2)
end

processor :fetch_data, threads: 20 do |id, output|
  data = HTTP.get("https://api.example.com/#{id}")
  output << data
end
```

### `consumer(name, options = {}, &block)`

Defines a stage that consumes data (has input, no output).

**Parameters:**
- `name` - Symbol stage name
- `options` - Hash of options (see [Stage Options](#stage-options))
- `block` - Block with one parameter: `item`

**Example:**
```ruby
consumer :save do |item|
  database.insert(item)
end

consumer :process, threads: 10 do |item|
  process_item(item)
end
```

### `accumulator(name, options = {}, &block)`

Defines a stage that batches multiple items before emitting.

**Parameters:**
- `name` - Symbol stage name
- `options` - Hash of options (must include `max_size`)
- `block` - Block with two parameters: `batch, output` OR `item, output`

**Options:**
- `max_size` - Integer, number of items to collect before emitting

**Example:**
```ruby
# Automatic batching
accumulator :batch, max_size: 100 do |batch, output|
  output << batch
end

# Custom batching logic
accumulator :custom_batch, max_size: 50 do |item, output|
  @items ||= []
  @items << item

  if @items.size >= 50
    batch = @items.dup
    @items.clear
    output << batch
  end
end
```

### `cow_fork(name, options = {}, &block)`

Alias for a consumer stage with COW fork execution.

**Parameters:**
- `name` - Symbol stage name
- `options` - Hash of options (see [Stage Options](#stage-options))
- `block` - Block with one parameter: `item`

**Example:**
```ruby
cow_fork :process, max: 4 do |batch|
  # Runs in forked process with copy-on-write memory
  batch.each { |item| expensive_computation(item) }
end
```

### `ipc_fork(name, options = {}, &block)`

Alias for a consumer stage with IPC fork execution.

**Parameters:**
- `name` - Symbol stage name
- `options` - Hash of options (see [Stage Options](#stage-options))
- `block` - Block with one parameter: `item`

**Example:**
```ruby
ipc_fork :process, max: 4 do |item|
  # Runs in persistent worker process
  @model ||= load_expensive_model
  @model.predict(item)
end
```

### `custom_stage(stage_class, name, options = {}, &block)`

Uses a custom Stage class.

**Parameters:**
- `stage_class` - Class inheriting from Minigun::Stage
- `name` - Symbol stage name
- `options` - Hash of options
- `block` - Optional block passed to stage

**Example:**
```ruby
class TimedBatchStage < Minigun::Stage
  def run_mode
    :streaming
  end

  def execute(context, item:, input_queue:, output_queue:)
    # Custom logic
  end
end

pipeline do
  producer :generate { ... }
  custom_stage TimedBatchStage, :batch, timeout: 5.0
  consumer :save { ... }
end
```

## Stage Options

Options available for all stage types:

### Routing Options

#### `from:`

Explicit upstream stages (Array or Symbol).

```ruby
processor :stage, from: :upstream do |item, output|
  # Receives items only from :upstream
end

processor :stage, from: [:upstream_a, :upstream_b] do |item, output|
  # Receives items from both upstreams
end
```

#### `to:`

Explicit downstream stages (Array or Symbol).

```ruby
processor :stage, to: :downstream do |item, output|
  # Sends to :downstream
end

processor :stage, to: [:downstream_a, :downstream_b] do |item, output|
  # Sends to both downstreams (fan-out)
end
```

#### `queues:`

Subscribe to named queues (Array of Symbols).

```ruby
processor :handler, queues: [:high_priority, :default] do |item, output|
  # Receives from these named queues
end
```

### Concurrency Options

#### `threads:`

Number of concurrent threads (Integer).

```ruby
processor :stage, threads: 10 do |item, output|
  # 10 threads process items concurrently
end
```

#### `processes:` or `max:`

Number of forked processes (Integer). Used with COW/IPC fork.

```ruby
processor :stage, execution: :cow_fork, max: 4 do |item, output|
  # Up to 4 concurrent forked processes
end
```

### Execution Options

#### `execution:`

Execution strategy (Symbol): `:inline`, `:thread`, `:cow_fork`, `:ipc_fork`.

```ruby
processor :stage, execution: :cow_fork, max: 8 do |item, output|
  # Overrides default execution strategy
end
```

### Queue Options

#### `queue_size:`

Input queue size (Integer or Float::INFINITY).

```ruby
processor :stage, queue_size: 100 do |item, output|
  # Input queue holds max 100 items
end

processor :stage, queue_size: Float::INFINITY do |item, output|
  # Unbounded queue
end
```

## Configuration Methods

### `execution(strategy, options = {})`

Sets default execution strategy for pipeline.

**Parameters:**
- `strategy` - Symbol: `:inline`, `:thread`, `:cow_fork`, `:ipc_fork`
- `options` - Hash of strategy-specific options

**Example:**
```ruby
class MyTask
  include Minigun::DSL

  execution :thread, max: 20

  pipeline do
    # Stages use thread execution by default
  end
end
```

### `max_threads(count)`

Sets maximum threads for thread pool execution.

**Example:**
```ruby
class MyTask
  include Minigun::DSL

  max_threads 50

  pipeline do
    # ...
  end
end
```

### `max_processes(count)`

Sets maximum processes for fork execution.

**Example:**
```ruby
class MyTask
  include Minigun::DSL

  max_processes 8

  pipeline do
    # ...
  end
end
```

## Lifecycle Hooks

### `before_run(&block)`

Executes before pipeline starts.

**Example:**
```ruby
class MyTask
  include Minigun::DSL

  before_run do
    puts "Pipeline starting..."
    @start_time = Time.now
  end

  pipeline do
    # ...
  end
end
```

### `after_run(&block)`

Executes after pipeline completes.

**Example:**
```ruby
after_run do
  duration = Time.now - @start_time
  puts "Pipeline completed in #{duration}s"
end
```

### `before_fork(&block)`

Executes in parent process before forking.

**Example:**
```ruby
before_fork do
  # Close database connections before fork
  ActiveRecord::Base.connection.disconnect!
end
```

### `after_fork(&block)`

Executes in child process after forking.

**Example:**
```ruby
after_fork do
  # Reconnect in child process
  ActiveRecord::Base.establish_connection
end
```

## Instance Methods

### `#run(options = {})`

Runs the pipeline.

**Parameters:**
- `options` - Hash of run options
  - `background: true` - Run in background thread (returns immediately)

**Returns:** Hash with `:status`, `:duration`, `:stats`

**Example:**
```ruby
task = MyTask.new
result = task.run

puts "Status: #{result[:status]}"
puts "Duration: #{result[:duration]}s"

# Background execution
task.run(background: true)
```

### `#hud`

Opens HUD monitor for running pipeline (requires `background: true`).

**Example:**
```ruby
task = MyTask.new
task.run(background: true)
task.hud  # Opens HUD
```

### `#running?`

Returns true if pipeline is running in background.

**Example:**
```ruby
task.running?  # => true or false
```

### `#stop`

Stops background execution.

**Example:**
```ruby
task.stop
```

### `#wait`

Waits for background pipeline to complete.

**Example:**
```ruby
task.run(background: true)
task.wait  # Blocks until complete
```

## Output Methods

Available in stage blocks via the `output` parameter.

### `output << item`

Emits item to all downstream stages.

```ruby
processor :stage do |item, output|
  output << transform(item)
end
```

### `output.to(stage_name) << item`

Emits item to specific downstream stage (dynamic routing).

```ruby
processor :route do |item, output|
  if item[:priority] == :high
    output.to(:high_priority) << item
  else
    output.to(:normal_priority) << item
  end
end
```

## Complete Example

```ruby
class CompleteExample
  include Minigun::DSL

  # Configuration
  execution :thread, max: 20
  max_threads 50

  # Hooks
  before_run do
    @start = Time.now
    @results = []
  end

  after_run do
    puts "Processed #{@results.size} items in #{Time.now - @start}s"
  end

  # Pipeline
  pipeline do
    # Producer
    producer :generate do |output|
      100.times { |i| output << i }
    end

    # Processor with threads
    processor :fetch, threads: 20 do |id, output|
      data = HTTP.get("https://api.example.com/#{id}")
      output << data
    end

    # Processor with routing
    processor :route, to: [:high, :normal] do |data, output|
      if data[:priority] == :high
        output.to(:high) << data
      else
        output.to(:normal) << data
      end
    end

    # Handlers
    processor :high, queues: [:high], threads: 10 do |data, output|
      output << process_urgent(data)
    end

    processor :normal, queues: [:normal], threads: 5 do |data, output|
      output << process_normal(data)
    end

    # Accumulator
    accumulator :batch, max_size: 50 do |batch, output|
      output << batch
    end

    # Consumer with forks
    consumer :save, execution: :cow_fork, max: 4 do |batch|
      database.insert_many(batch)
      @results.concat(batch)
    end
  end
end

# Run it
CompleteExample.new.run
```

## See Also

- [Stage API](stage.md) - Stage class methods
- [Pipeline API](pipeline.md) - Pipeline class methods
- [Guide: Hello World](../guides/02_hello_world.md) - Basic usage
- [Guides: Stages](../guides/stages/overview.md) - Stage types in depth
