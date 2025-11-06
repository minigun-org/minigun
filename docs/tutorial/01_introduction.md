# Introduction to Minigun

Welcome to Minigun! This tutorial will guide you through the core concepts and features of Minigun, a high-performance data processing pipeline framework for Ruby.

## What is Minigun?

Minigun is a framework for building **data processing pipelines** in Ruby. Think of it as a way to take data from a source, transform it through multiple stages, and output the results—all with built-in parallelism and concurrency.

### A Simple Example

```ruby
class HelloPipeline
  include Minigun::DSL

  pipeline do
    producer :generate do |output|
      5.times { |i| output << i }
    end

    processor :double do |number, output|
      output << (number * 2)
    end

    consumer :print do |result|
      puts "Result: #{result}"
    end
  end
end

HelloPipeline.new.run
# Output:
# Result: 0
# Result: 2
# Result: 4
# Result: 6
# Result: 8
```

This pipeline has three **stages**:
1. **Producer** (`generate`) - Creates numbers 0 through 4
2. **Processor** (`double`) - Multiplies each number by 2
3. **Consumer** (`print`) - Prints the results

## When to Use Minigun

Minigun excels at:

- **ETL (Extract, Transform, Load)** - Moving data between systems
- **Batch Processing** - Processing large datasets in parallel
- **Stream Processing** - Real-time data transformation
- **Web Scraping** - Parallel crawling and processing
- **Data Pipelines** - Complex multi-stage data workflows

### ✅ Use Minigun When:

- You need in-memory data processing pipelines
- You want to parallelize work across threads or processes
- You're building streaming data workflows
- You want to avoid external dependencies (Redis, databases)
- You need fine-grained control over concurrency

### ❌ Consider Alternatives When:

- You need persistent job queues (consider Sidekiq, Resque)
- Jobs must survive process restarts (use a database-backed queue)
- You need distributed processing across multiple machines
- Jobs run for hours or days (use long-running worker systems)

## Core Concepts

### Pipelines

A **pipeline** is a collection of connected stages that process data. Data flows from producers through processors to consumers.

```
Producer → Processor → Processor → Consumer
```

### Stages

**Stages** are the building blocks of pipelines. There are four types:

1. **Producer** - Generates data (no input, only output)
2. **Processor** - Transforms data (input and output)
3. **Accumulator** - Batches multiple items into groups
4. **Consumer** - Final processing (input, no output)

### Execution Strategies

Minigun supports multiple ways to execute stages:

- **Inline** - Sequential, single-threaded (debugging)
- **Thread Pool** - Concurrent threads (I/O-bound work)
- **COW Fork** - Forked processes with copy-on-write (CPU-bound with large data)
- **IPC Fork** - Persistent worker processes (CPU-bound, long-running)

### Data Flow

Data moves through the pipeline via **queues**. Each stage:
1. Pulls items from its input queue
2. Processes the item
3. Emits results to its output queue
4. The output queue connects to the next stage's input queue

## Why Minigun?

### Zero Dependencies
Pure Ruby implementation. No Redis, PostgreSQL, or message brokers required. Everything runs in memory within your Ruby process.

### Flexible Execution
Mix thread pools, forked processes, and different strategies within a single pipeline. Choose the right tool for each stage.

### Composable
Build complex systems by nesting pipelines. Create reusable pipeline components.

### Observable
Built-in HUD shows real-time metrics: throughput, latency, bottlenecks, and more.

## Installation

Add to your Gemfile:

```ruby
gem 'minigun'
```

Or install directly:

```bash
gem install minigun
```

**Requirements:**
- Ruby 2.7 or higher
- No external dependencies

**Platform Notes:**
- Full support on MRI Ruby
- JRuby supported (thread-only execution, no fork)

## What You'll Learn

In this tutorial series, you'll learn:

1. **Introduction** (this page) - What is Minigun?
2. **[Hello World](02_hello_world.md)** - Your first pipeline
3. **[Stages](03_stages.md)** - Understanding stage types
4. **[Routing](04_routing.md)** - Connecting stages
5. **[Concurrency](05_concurrency.md)** - Adding parallelism
6. **[Execution Strategies](06_execution_strategies.md)** - Threads vs forks
7. **[Monitoring](07_monitoring.md)** - Using the HUD

Each lesson builds on the previous ones, so we recommend going through them in order.

## Next Steps

Ready to build your first pipeline? Let's start with a simple Hello World example.

→ [**Continue to Hello World**](02_hello_world.md)

---

**Additional Resources:**
- [Examples Directory](../../examples/) - 100+ working examples
- [API Reference](../api/) - Complete API documentation
- [Recipes](../recipes/) - Common patterns and solutions
