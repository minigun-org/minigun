![Minigun](https://github.com/user-attachments/assets/201793a7-ffb1-474b-bb1d-1e739c028d09)

# Minigun go BRRRRR

Composable, high-performance data processing pipelines for Ruby.

```ruby
require 'minigun'

class DataPipeline
  include Minigun::DSL

  pipeline do
    producer :generate do |output|
      100.times { |i| output << i }
    end

    processor :transform, threads: 10 do |number, output|
      output << (number * 2)
    end

    accumulator :batch, max_size: 20 do |batch, output|
      output << batch
    end

    consumer :save do |batch|
      database.insert_many(batch)
    end
  end
end

DataPipeline.new.run
```

## Why Minigun?

**Full-Stack Parallelism** - Thread pools, COW forks, and IPC workers—all in one framework.

**Zero Dependencies** - Pure Ruby. No Redis, no PostgreSQL, no external services.

**Composable by Design** - Build complex systems by composing simple stages.

**Observable** - Real-time monitoring with built-in HUD interface.

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
- Ruby 3.2 or higher
- No external dependencies

## Quick Links

### Learning

- **[Comparison](docs/comparison.md)** - When to use Minigun vs SolidQueue, Sidekiq, etc.
- **[Guides](docs/guides/01_introduction.md)** - Learn Minigun in step-by-step lessons
- **[Recipes](docs/recipes/)** - Practical examples for common use cases
- **[Examples](examples/)** - Tons of working examples

## Features

- **Multiple execution strategies** - Inline, threads, COW forks, IPC workers
- **Advanced routing** - Sequential, fan-out, fan-in, dynamic routing
- **Nested pipelines** - Compose pipelines within pipelines
- **Built-in monitoring** - Real-time HUD with throughput and latency metrics
- **Automatic backpressure** - Bounded queues prevent memory exhaustion
- **Thread-safe** - Works with Ruby's concurrency primitives

## Use Cases

Minigun excels at:

- **ETL pipelines** - Extract, transform, load data between systems
- **Web scraping** - Parallel crawling and data extraction
- **Batch processing** - Process large datasets efficiently
- **Stream processing** - Real-time data transformation
- **Data pipelines** - Complex multi-stage workflows

[When should I use Minigun?](docs/comparison.md)

## Quick Example: Web Scraper

```ruby
class WebScraper
  include Minigun::DSL

  pipeline do
    producer :urls do |output|
      urls.each { |url| output << url }
    end

    processor :fetch, threads: 20 do |url, output|
      output << HTTP.get(url).body
    end

    processor :parse, threads: 5 do |html, output|
      output << Nokogiri::HTML(html)
    end

    consumer :save do |doc|
      save_to_database(doc)
    end
  end
end
```

### Recipes

- [ETL Pipeline](docs/recipes/etl_pipeline.md) - Extract, transform, load
- [Web Crawler](docs/recipes/web_crawler.md) - Parallel web scraping
- [Batch Processing](docs/recipes/batch_processing.md) - Process large datasets
- [Priority Queues](docs/recipes/priority_queues.md) - Route by priority
- [More recipes →](docs/recipes/)

## Documentation

**[→ Browse Full Documentation](docs/index.md)**

### Getting Started

1. [Introduction](docs/guides/01_introduction.md) - What is Minigun?
2. [Hello World](docs/guides/02_hello_world.md) - Your first pipeline
3. [Understanding Stages](docs/guides/03_stages.md) - Producers, processors, consumers
4. [Routing](docs/guides/04_routing.md) - Connecting stages
5. [Concurrency](docs/guides/05_concurrency.md) - Adding parallelism
6. [Execution Strategies](docs/guides/06_execution_strategies.md) - Threads vs forks
7. [Monitoring](docs/guides/07_monitoring.md) - Using the HUD
8. [Deployment](docs/guides/08_deployment.md) - Production deployment
9. [API Reference](docs/guides/09_api_reference.md) - Complete DSL documentation
10. [HUD Monitor](docs/guides/10_hud.md) - Real-time pipeline monitoring
11. [Performance Tuning](docs/guides/11_performance_tuning.md) - Optimization strategies
12. [Testing](docs/guides/12_testing.md) - Testing your pipelines
13. [Contributing](docs/guides/13_contributing.md) - How to contribute
14. [Error Handling](docs/guides/14_error_handling.md) - Strategies for handling failures
15. [Configuration](docs/guides/15_configuration.md) - Global and stage-level configuration
16. [Fundamentals](docs/guides/16_fundamentals.md) - Deep dive into queues, forking, threads, ractors, and fibers

### Reference

- [Architecture](docs/architecture/system_architecture.md) - How Minigun works under the hood

## Contributing

Contributions welcome! See the [Contributing Guide](docs/guides/13_contributing.md) or check the [Issue Tracker](https://github.com/user/minigun/issues).

## License

Minigun is available as open source under the terms of the [MIT License](LICENSE).

---

**Ready to get started?** [Read the Guides →](docs/guides/01_introduction.md)
