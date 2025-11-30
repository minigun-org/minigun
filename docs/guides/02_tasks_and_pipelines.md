# Tasks and Pipelines

This guide covers how to organize your Minigun code using tasks, pipelines, named pipelines, and inheritance.

## Basic Structure

Every Minigun application starts with a class that includes the DSL:

```ruby
class MyTask
  include Minigun::DSL

  pipeline do
    producer :source do |output|
      output << "Hello"
    end

    consumer :sink do |item|
      puts item
    end
  end
end

MyTask.new.run
```

## Understanding Tasks vs Pipelines

- **Task**: A Ruby class that includes `Minigun::DSL`. It holds configuration and one or more pipelines.
- **Pipeline**: A collection of stages that process data. Defined with `pipeline do ... end`.
- **Stage**: A single processing unit (producer, processor, consumer, batch).

```
Task
 └── root_pipeline
      ├── Stage: source
      ├── Stage: transform
      └── Stage: sink
```

## Unnamed Pipelines

The simplest form is an unnamed pipeline. Stages go directly on the task's root pipeline:

```ruby
class SimpleTask
  include Minigun::DSL

  pipeline do
    producer :generate do |output|
      [1, 2, 3].each { |n| output << n }
    end

    processor :double do |n, output|
      output << n * 2
    end

    consumer :print do |n|
      puts n
    end
  end
end
```

You can have multiple unnamed pipelines—their stages all share the root pipeline:

```ruby
class MultiProducerTask
  include Minigun::DSL

  # First pipeline block
  pipeline do
    producer :source_a do |output|
      output << "A"
    end
  end

  # Second pipeline block - stages also go on root
  pipeline do
    producer :source_b do |output|
      output << "B"
    end

    consumer :collect do |item|
      @results << item
    end
  end
end
```

Both producers feed into the shared root pipeline.

## Named Pipelines

Named pipelines create isolated sub-pipelines that can route to each other:

```ruby
class NamedPipelineTask
  include Minigun::DSL

  pipeline :etl_a do
    producer :source_a do |output|
      [1, 2, 3].each { |n| output << n }
    end

    consumer :sink_a do |n|
      puts "Pipeline A: #{n}"
    end
  end

  pipeline :etl_b do
    producer :source_b do |output|
      [10, 20, 30].each { |n| output << n }
    end

    consumer :sink_b do |n|
      puts "Pipeline B: #{n}"
    end
  end
end
```

Named pipelines run in parallel, independently.

### Routing Between Named Pipelines

Named pipelines can route to stages on the root or to each other:

```ruby
class RoutedPipelineTask
  include Minigun::DSL

  # Shared stages on root (unnamed pipeline)
  pipeline do
    processor :transform do |item, output|
      output << item * 10
    end

    consumer :collect do |item|
      @results << item
    end
  end

  # Named pipeline routes TO the shared transform stage
  pipeline :producer_pipeline, to: :transform do
    producer :source do |output|
      [1, 2, 3].each { |n| output << n }
    end

    consumer :forward do |item, output|
      output << item
    end
  end
end
```

Data flows: `source → forward → transform → collect`

## Named Pipeline Extension

Declaring a named pipeline multiple times **extends** it (adds stages):

```ruby
class ExtendedPipelineTask
  include Minigun::DSL

  pipeline :main do
    producer :source do |output|
      [1, 2, 3].each { |n| output << n }
    end

    consumer :collect do |n|
      @results << n
    end
  end

  # Extend :main by declaring it again
  pipeline :main do
    processor :double do |n, output|
      output << n * 2
    end

    # Reroute to insert the processor
    reroute_stage :source, to: :double
    reroute_stage :double, to: :collect
  end
end
```

Result: Items flow `source → double → collect` producing `[2, 4, 6]`.

## Pipeline Inheritance

Child classes inherit parent pipelines and can extend them.

### Basic Inheritance

```ruby
class BaseTask
  include Minigun::DSL

  attr_accessor :results

  def initialize
    @results = []
  end

  pipeline do
    producer :source do |output|
      [1, 2, 3].each { |n| output << n }
    end

    consumer :collect do |n|
      @results << n
    end
  end
end

# Child inherits parent's pipeline
class ChildTask < BaseTask
end

ChildTask.new.run  # Works! Produces [1, 2, 3]
```

### Extending Inherited Pipelines

Children can add stages and reroute:

```ruby
class ExtendedTask < BaseTask
  pipeline do
    processor :double do |n, output|
      output << n * 2
    end

    # Insert processor between source and collect
    reroute_stage :source, to: :double
    reroute_stage :double, to: :collect
  end
end

task = ExtendedTask.new
task.run
puts task.results  # [2, 4, 6]
```

### Multi-Level Inheritance

Inheritance works through multiple levels:

```ruby
class GrandparentTask
  include Minigun::DSL

  pipeline do
    producer :source do |output|
      output << 1
    end

    consumer :collect do |n|
      @results << n
    end
  end
end

class ParentTask < GrandparentTask
  pipeline do
    processor :double do |n, output|
      output << n * 2
    end

    reroute_stage :source, to: :double
    reroute_stage :double, to: :collect
  end
end

class ChildTask < ParentTask
  pipeline do
    processor :add_ten do |n, output|
      output << n + 10
    end

    reroute_stage :double, to: :add_ten
    reroute_stage :add_ten, to: :collect
  end
end

# Flow: source(1) → double(2) → add_ten(12) → collect
# Result: [12]
```

### Extending Named Pipelines via Inheritance

```ruby
class BaseWithNamed
  include Minigun::DSL

  pipeline :main do
    producer :source do |output|
      [10, 20].each { |n| output << n }
    end

    consumer :collect do |n|
      @results << n
    end
  end
end

class ExtendedNamed < BaseWithNamed
  # Extend parent's :main pipeline
  pipeline :main do
    processor :add_five do |n, output|
      output << n + 5
    end

    reroute_stage :source, to: :add_five
    reroute_stage :add_five, to: :collect
  end
end

# Result: [15, 25]
```

## Configuration Inheritance

Children inherit parent configuration and can override:

```ruby
class BaseTask
  include Minigun::DSL

  max_threads 10
  max_processes 4
end

class ChildTask < BaseTask
  max_threads 20  # Override
  # max_processes remains 4
end
```

## Best Practices

### 1. Use Named Pipelines for Independent Flows

```ruby
# Good: Clear separation
pipeline :import_users do
  # ...
end

pipeline :import_orders do
  # ...
end
```

### 2. Use Unnamed Pipelines for Shared Stages

```ruby
# Shared processing on root
pipeline do
  processor :validate do |item, output|
    output << item if item.valid?
  end

  consumer :save do |item|
    database.insert(item)
  end
end

# Named pipelines route to shared stages
pipeline :from_api, to: :validate do
  producer :fetch_api do |output|
    # ...
  end
end

pipeline :from_file, to: :validate do
  producer :read_file do |output|
    # ...
  end
end
```

### 3. Use Inheritance for Reusable Patterns

```ruby
class BasePublisher
  include Minigun::DSL

  pipeline do
    processor :format do |item, output|
      output << format_message(item)
    end

    consumer :publish do |message|
      publish_to_queue(message)
    end
  end

  def format_message(item)
    raise NotImplementedError
  end
end

class OrderPublisher < BasePublisher
  pipeline do
    producer :fetch_orders do |output|
      Order.pending.each { |o| output << o }
    end
  end

  def format_message(order)
    { type: 'order', id: order.id, total: order.total }
  end
end
```

### 4. Keep Pipelines Focused

Each pipeline should have a single responsibility:

```ruby
# Good: Focused pipelines
pipeline :extract do
  producer :read_source do |output|
    # Extract data
  end
end

pipeline :transform, from: :extract do
  processor :clean do |item, output|
    # Transform data
  end
end

pipeline :load, from: :transform do
  consumer :write_destination do |item|
    # Load data
  end
end
```

## Summary

| Concept | Behavior |
|---------|----------|
| Unnamed `pipeline do` | Stages go on root (shared) |
| Named `pipeline :name do` | Creates isolated sub-pipeline |
| Same name twice | Extends existing pipeline |
| Child class | Inherits parent's blocks |
| Child adds `pipeline do` | Extends parent's root pipeline |
| Child adds `pipeline :name do` | Extends parent's named pipeline |

## What's Next?

Now that you understand how to organize pipelines, let's look at a simple example.

→ [**Continue to Hello World**](02_hello_world.md)

---

**See Also:**
- [Hello World](02_hello_world.md) - Your first pipeline
- [Stages Guide](03_stages.md) - Stage types in detail
- [Routing Guide](04_routing.md) - Connecting stages
- [Architecture: Pipeline Inheritance](../architecture/pipeline_inheritance.md) - Technical details
