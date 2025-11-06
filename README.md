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

- **[Tutorial](docs/tutorial/01_introduction.md)** - Learn Minigun step-by-step (7 lessons)
- **[Recipes](docs/recipes/)** - Practical examples for common use cases
- **[Examples](examples/)** - 100+ working examples

### Reference

- **[API Documentation](docs/api/)** - Complete API reference
- **[Architecture](docs/architecture/system_architecture.md)** - How Minigun works under the hood
- **[Guides](docs/guides/)** - Deep dives into specific features

### Tools

- **[HUD Monitor](docs/hud/overview.md)** - Real-time pipeline monitoring
- **[Performance Tuning](docs/advanced/performance_tuning.md)** - Optimization strategies

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

[When should I use Minigun?](docs/comparison/when_to_use.md)

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

[More examples →](examples/)

## Documentation

### Getting Started

1. [Introduction](docs/tutorial/01_introduction.md) - What is Minigun?
2. [Hello World](docs/tutorial/02_hello_world.md) - Your first pipeline
3. [Understanding Stages](docs/tutorial/03_stages.md) - Producers, processors, consumers
4. [Routing](docs/tutorial/04_routing.md) - Connecting stages
5. [Concurrency](docs/tutorial/05_concurrency.md) - Adding parallelism
6. [Execution Strategies](docs/tutorial/06_execution_strategies.md) - Threads vs forks
7. [Monitoring](docs/tutorial/07_monitoring.md) - Using the HUD

### Recipes

- [ETL Pipeline](docs/recipes/etl_pipeline.md) - Extract, transform, load
- [Web Crawler](docs/recipes/web_crawler.md) - Parallel web scraping
- [More recipes →](docs/recipes/)

### Complete Documentation

**[→ Browse Full Documentation](docs/index.md)**

## Contributing

Contributions welcome! Please see:

- [Development Setup](docs/contributing/development.md)
- [Running Tests](docs/contributing/testing.md)
- [Issue Tracker](https://github.com/user/minigun/issues)

## License

Minigun is available as open source under the terms of the [MIT License](LICENSE).

---

**Ready to get started?** [Begin the Tutorial →](docs/tutorial/01_introduction.md)
