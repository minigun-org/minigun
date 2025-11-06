# Recipes

Practical, working examples for common use cases. Each recipe is a complete solution you can adapt for your needs.

## Getting Started

New to Minigun? Start with the [Guide](../guides/01_introduction.md) first, then come back here for practical examples.

## Available Recipes

### Data Processing

#### [ETL Pipeline](etl_pipeline.md)
Extract data from a source, transform it, and load it into a destination. Covers data cleaning, validation, enrichment, batching, and error handling.

**Best for:** Data migrations, database sync, data transformation

**Key concepts:** Producer, processor, accumulator, consumer, batching, error handling

---

#### [Batch Processing](batch_processing.md)
Process large datasets efficiently by streaming, batching, and parallelizing. Handle millions of records without running out of memory.

**Best for:** Large dataset processing, data imports, bulk operations

**Key concepts:** Streaming, batching, memory management, throughput optimization, priority routing

---

### Web & Network

#### [Web Crawler](web_crawler.md)
Crawl websites in parallel, extract links, and process content. Handle errors gracefully with rate limiting and retries.

**Best for:** Web scraping, data collection, link extraction

**Key concepts:** High concurrency, error handling, recursive crawling, feedback loops

---

### Routing Patterns

#### [Priority Queues](priority_queues.md)
Route items by priority for differentiated processing. High-priority items get more resources and faster processing.

**Best for:** SLA-based processing, urgent vs normal workflows, load management

**Key concepts:** Queue-based routing, dynamic routing, resource allocation

---

#### [Fan-Out / Fan-In](fan_out_fan_in.md)
Split data to multiple parallel paths, then merge results back together. Process through different transformations simultaneously.

**Best for:** Parallel transformations, multi-path processing, result aggregation

**Key concepts:** Fan-out, fan-in, parallel processing, result merging

---

## Coming Soon

More recipes in development:

- **Error Recovery** - Retry strategies and dead letter queues
- **Real-Time Stream Processing** - Process streaming data sources
- **Multi-Source Aggregation** - Combine data from multiple sources
- **Data Validation Pipeline** - Validate and filter data through multiple rules
- **Image Processing** - Parallel image transformation and optimization
- **API Client** - Parallel API request handling with rate limiting

## Recipe Template

Each recipe follows this structure:

### Problem
What problem does this solve? When would you use this pattern?

### Solution
Complete, working code example.

### How It Works
Explanation of how the solution works.

### Variations
Alternative approaches and modifications.

### Performance
Optimization tips and tuning advice.

### Key Takeaways
Summary of important concepts.

## Using Recipes

### Copy and Adapt

Recipes are designed to be copied and modified:

1. Find a recipe that matches your use case
2. Copy the code
3. Modify for your specific needs
4. Test and tune

### Combine Patterns

Mix and match recipes for complex workflows:

```ruby
class ComplexPipeline
  include Minigun::DSL

  pipeline do
    # ETL pattern
    producer :extract { ... }
    processor :transform, threads: 10 { ... }

    # Priority routing
    processor :route_by_priority do |item, output|
      output.to("#{item[:priority]}_queue") << item
    end

    # Fan-out pattern for high priority
    processor :high_handler,
              queues: [:high_queue],
              to: [:path_a, :path_b],
              threads: 20 { ... }

    # Batch pattern
    accumulator :batch, max_size: 500 { ... }
    consumer :load, threads: 4 { ... }
  end
end
```

## Getting Help

- **Examples Directory** - See [examples/](../../examples/) for 100+ working examples
- **Guides** - Read [Guides](../guides/) for deep dives into specific features
- **Guide** - Go through the [Guide](../guides/01_introduction.md) for fundamentals
- **API Reference** - Check [API docs](09_api_reference.md) for detailed method documentation

## Contributing Recipes

Have a recipe to share? We'd love to add it!

1. Fork the repository
2. Create your recipe in `docs/recipes/`
3. Follow the recipe template
4. Submit a pull request

See [Contributing](13_contributing.md) for details.

---

**Ready to start?** Pick a recipe above or [browse all documentation →](../index.md)
