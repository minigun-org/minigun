# Minigun Documentation

## Composable parallel data processing

Minigun is a high-performance data processing pipeline framework for Ruby. Build complex, parallel workflows with multiple execution strategies—all in pure Ruby with zero external dependencies.

```ruby
class DataProcessor
  include Minigun::DSL

  pipeline do
    producer :fetch_data do |output|
      Database.find_each { |record| output << record }
    end

    consumer :transform, threads: 10 do |record, output|
      output << transform(record)
    end

    batch(100)

    consumer :save, cow_forks: 4 do |batch|
      batch.each { |record| save_to_file(record) }
    end
  end
  
  def transform(record)
    # your logic
  end

  def save_to_file(record)
    # your logic
  end
end

DataProcessor.new.run
```

## Why Minigun?

### Full-Stack Parallelism
Choose your execution strategy: thread pools for I/O-bound work, COW forks for CPU-intensive tasks with large datasets, or IPC workers for persistent process pools. Mix and match within a single pipeline.

### Zero Dependencies
Pure Ruby implementation. No Redis, no PostgreSQL, no message brokers. Run entirely in memory with no external infrastructure.

### Composable by Design
Build complex systems by composing simple stages. Nest pipelines within pipelines. Create reusable components that work together seamlessly.

### Observable Out of the Box
Monitor your pipelines in real-time with the built-in HUD interface. View throughput, latency percentiles, and bottlenecks as your data flows through the system.

## Three Ways to Learn

### 📚 Tutorial: Tour of Minigun

Take a guided tour through Minigun's core concepts. Build your understanding step-by-step from first principles to advanced patterns.

**Start Here If:** You're new to Minigun or want to understand the fundamentals.

→ [**Start the Tutorial**](tutorial/01_introduction.md)

---

### 🍳 Recipes: Practical Examples

Jump straight to working code for common use cases. Each recipe is a complete, runnable example with discussion of trade-offs and alternatives.

**Start Here If:** You learn best by example and want to see real-world patterns.

→ [**Browse Recipes**](recipes/)

**Popular Recipes:**
- [ETL Pipeline](recipes/etl_pipeline.md) - Extract, transform, and load data
- [Web Crawler](recipes/web_crawler.md) - Parallel web scraping
- [Batch Processing](recipes/batch_processing.md) - Process large datasets efficiently
- [Priority Queues](recipes/priority_queues.md) - Route by priority
- [Fan-out/Fan-in](recipes/fan_out_fan_in.md) - Parallel processing with merge

---

### 📖 API Reference

Complete reference documentation for all classes, methods, and configuration options.

**Start Here If:** You know what you're looking for and need detailed API information.

→ [**View API Reference**](api/)

---

## Feature Guides

Comprehensive guides organized by topic:

### Stages
- [Overview](guides/stages/overview.md) - Understanding stage types
- [Producers](guides/stages/producers.md) - Generating data
- [Processors](guides/stages/processors.md) - Transforming data
- [Consumers](guides/stages/consumers.md) - Terminal processing
- [Accumulators](guides/stages/accumulators.md) - Batching strategies
- [Custom Stages](guides/stages/custom_stages.md) - Build your own

### Routing
- [Overview](guides/routing/overview.md) - Routing strategies
- [Sequential](guides/routing/sequential.md) - Default flow
- [Explicit](guides/routing/explicit.md) - Using `from:` and `to:`
- [Queue-Based](guides/routing/queue_based.md) - Named queue routing
- [Dynamic](guides/routing/dynamic.md) - Runtime routing decisions

### Execution Strategies
- [Overview](guides/execution/overview.md) - Choosing the right strategy
- [Inline](guides/execution/inline.md) - Single-threaded (debugging)
- [Thread Pool](guides/execution/thread_pool.md) - Shared-memory concurrency
- [COW Fork](guides/execution/cow_fork.md) - Copy-on-write processes
- [IPC Fork](guides/execution/ipc_fork.md) - Persistent worker pools

### More Guides
- [Configuration](guides/configuration.md) - Configure pipelines and stages
- [Hooks](guides/hooks.md) - Lifecycle hooks
- [Queue Management](guides/queue_management.md) - Backpressure and flow control
- [Error Handling](guides/error_handling.md) - Retry and recovery strategies
- [Nested Pipelines](guides/composition/nested_pipelines.md) - Composing pipelines

---

## HUD: Real-Time Monitoring

Monitor your pipelines with the built-in heads-up display.

- [Overview](hud/overview.md) - Introduction to the HUD
- [Quick Start](hud/quick_start.md) - Get started in 60 seconds
- [Interface Guide](hud/interface.md) - Understanding the UI
- [Metrics](hud/metrics.md) - Reading performance data

---

## Architecture

Understand how Minigun works under the hood.

- [System Architecture](architecture/system_architecture.md) - High-level overview
- [Pipeline & DAG](architecture/pipeline_and_dag.md) - Routing and graph structure
- [Stage Execution Model](architecture/stage_execution.md) - How stages run
- [Queue System](architecture/queue_system.md) - Data flow internals
- [Termination Protocol](architecture/termination_protocol.md) - Shutdown mechanics
- [Design Decisions](architecture/design_decisions.md) - Why things work this way

---

## Advanced Topics

Deep dives for power users:

- [Yield Syntax](advanced/yield_syntax.md) - Class-based stages with Ruby yield
- [IPC Internals](advanced/ipc_internals.md) - Serialization and optimization
- [Performance Tuning](advanced/performance_tuning.md) - Optimization strategies
- [Extending Minigun](advanced/extending.md) - Custom executors and stage types

---

## Comparison & Migration

Choose the right tool for your use case:

- [When to Use Minigun](comparison/when_to_use.md) - Decision guide
- [Minigun vs Sidekiq](comparison/sidekiq.md)
- [Minigun vs Resque](comparison/resque.md)
- [Minigun vs Solid Queue](comparison/solid_queue.md)

---

## Contributing

Help make Minigun better:

- [Development Setup](contributing/development.md)
- [Running Tests](contributing/testing.md)
- [Code Style Guide](contributing/style_guide.md)

---

## Quick Links

- [Installation](#installation)
- [Examples Directory](../examples/) - 100+ working examples
- [GitHub Repository](https://github.com/user/minigun)
- [Issue Tracker](https://github.com/user/minigun/issues)

---

## Installation

Add Minigun to your Gemfile:

```ruby
gem 'minigun'
```

Or install directly:

```bash
gem install minigun
```

**Requirements:**
- Ruby 3.2 or higher
- No external dependencies

**Platform Support:**
- MRI Ruby (full support)
  - (MRI Ruby on Windows does not support forking)
- JRuby (thread-only execution, no fork support)
- TruffleRuby (thread-only execution, no fork support)

---

Ready to get started? [Begin the Tutorial →](tutorial/01_introduction.md)
