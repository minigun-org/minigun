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

### 📚 Guide: Tour of Minigun

Take a guided tour through Minigun's core concepts. Build your understanding step-by-step from first principles to advanced patterns.

**Start Here If:** You're new to Minigun or want to understand the fundamentals.

→ [**Start the Guide**](guides/01_introduction.md)

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

→ [**View API Reference**](guides/09_api_reference.md)

---

## HUD: Real-Time Monitoring

Monitor your pipelines with the built-in heads-up display.

→ [**HUD Overview**](guides/10_hud.md) - Real-time monitoring interface

---

## Architecture

Understand how Minigun works under the hood.

- [System Architecture](architecture/system_architecture.md) - Components and data flow
- [Design Decisions](architecture/design_decisions.md) - Why things work this way

---

## Comparison

Choose the right tool for your use case:

→ [**Comparison Guide**](comparison.md) - When to use Minigun vs Sidekiq

---

## Advanced Topics

- [**Performance Tuning**](guides/11_performance_tuning.md) - Optimization strategies
- [**Testing Your Pipelines**](guides/12_testing.md) - Testing patterns and best practices
- [**Error Handling**](guides/14_error_handling.md) - Strategies for handling failures in pipelines
- [**Configuration**](guides/15_configuration.md) - Global and stage-level configuration
- [**Fundamentals**](guides/16_fundamentals.md) - Deep dive into queues, COW/IPC forking, threads, ractors, and fibers

---

## Contributing

Help make Minigun better:

→ [**Contributing Guide**](guides/13_contributing.md) - How to contribute to Minigun

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

Ready to get started? [Read the Guides →](guides/01_introduction.md)
