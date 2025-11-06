# Recipe: Parallel Web Crawler

Crawl websites in parallel, extract links, and process content.

## Problem

You need to scrape data from hundreds or thousands of web pages. Sequential requests are too slow. You want parallel fetching with rate limiting and error handling.

## Solution

```ruby
require 'minigun'
require 'http'
require 'nokogiri'

class WebCrawler
  include Minigun::DSL

  attr_accessor :results, :errors

  def initialize(seed_urls, max_pages: 1000)
    @seed_urls = seed_urls
    @max_pages = max_pages
    @results = Concurrent::Array.new
    @errors = Concurrent::Array.new
    @visited = Concurrent::Set.new
    @page_count = Concurrent::AtomicFixnum.new(0)
  end

  pipeline do
    # Generate initial URLs
    producer :seed_urls do |output|
      @seed_urls.each { |url| output << url }
    end

    # Filter already-visited URLs
    processor :filter_visited do |url, output|
      if @visited.add?(url)  # Thread-safe set operation
        if @page_count.increment < @max_pages
          output << url
        end
      end
    end

    # Fetch pages in parallel (I/O-bound)
    processor :fetch, threads: 20 do |url, output|
      begin
        response = HTTP.timeout(10).get(url)

        if response.status.success?
          output << {
            url: url,
            body: response.body.to_s,
            status: response.status.code,
            fetched_at: Time.now
          }
        else
          @errors << { url: url, error: "HTTP #{response.status.code}" }
        end
      rescue HTTP::TimeoutError => e
        @errors << { url: url, error: 'Timeout' }
      rescue => e
        @errors << { url: url, error: e.message }
      end
    end

    # Parse HTML and extract links
    processor :parse, threads: 5 do |page, output|
      begin
        doc = Nokogiri::HTML(page[:body])

        parsed = {
          url: page[:url],
          title: doc.at_css('title')&.text&.strip,
          links: extract_links(doc, page[:url]),
          meta: extract_meta(doc),
          fetched_at: page[:fetched_at]
        }

        output << parsed
      rescue => e
        @errors << { url: page[:url], error: "Parse error: #{e.message}" }
      end
    end

    # Extract and emit new links to crawl
    processor :extract_links do |parsed, output|
      # Emit parsed page for storage
      output << parsed

      # Also emit new links back to filter_visited
      parsed[:links].each do |link|
        output.to(:filter_visited) << link
      end
    end

    # Store results
    consumer :store do |parsed|
      @results << parsed
    end
  end

  private

  def extract_links(doc, base_url)
    doc.css('a[href]').map do |link|
      href = link['href']
      next if href.nil? || href.empty?
      next if href.start_with?('#', 'javascript:', 'mailto:')

      # Convert relative URLs to absolute
      URI.join(base_url, href).to_s
    rescue URI::InvalidURIError
      nil
    end.compact.uniq
  end

  def extract_meta(doc)
    {
      description: doc.at_css('meta[name="description"]')&.[]('content'),
      keywords: doc.at_css('meta[name="keywords"]')&.[]('content'),
      author: doc.at_css('meta[name="author"]')&.[]('content')
    }
  end
end

# Run the crawler
crawler = WebCrawler.new(
  ['https://example.com'],
  max_pages: 100
)

result = crawler.run

puts "\n=== Crawl Complete ==="
puts "Pages crawled: #{crawler.results.size}"
puts "Errors: #{crawler.errors.size}"
puts "Duration: #{result[:duration].round(2)}s"
puts "Rate: #{(crawler.results.size / result[:duration]).round(2)} pages/s"
```

## How It Works

### Seed URLs

```ruby
producer :seed_urls do |output|
  @seed_urls.each { |url| output << url }
end
```

- Emits initial URLs to start crawling
- Can add multiple seed URLs

### Filtering

```ruby
processor :filter_visited do |url, output|
  if @visited.add?(url)  # Thread-safe add
    if @page_count.increment < @max_pages
      output << url
    end
  end
end
```

- Prevents visiting the same URL twice
- Limits total pages crawled
- Uses `Concurrent::Set` for thread-safety

### Fetching

```ruby
processor :fetch, threads: 20 do |url, output|
  response = HTTP.timeout(10).get(url)
  output << { url: url, body: response.body.to_s }
end
```

- 20 concurrent threads for parallel fetching
- 10-second timeout per request
- Captures errors without crashing

### Parsing

```ruby
processor :parse, threads: 5 do |page, output|
  doc = Nokogiri::HTML(page[:body])
  # Extract title, links, metadata
end
```

- 5 threads for CPU-bound HTML parsing
- Extracts structured data from HTML

### Link Extraction

```ruby
processor :extract_links do |parsed, output|
  output << parsed  # Store this page

  parsed[:links].each do |link|
    output.to(:filter_visited) << link  # Crawl new links
  end
end
```

- **Feedback loop:** New links go back to filter_visited
- Enables recursive crawling
- Uses dynamic routing with `output.to()`

## Variations

### Respect robots.txt

```ruby
require 'robots'

processor :check_robots do |url, output|
  robots = Robots.new('YourBot/1.0')

  if robots.allowed?(url)
    output << url
  else
    logger.info("Blocked by robots.txt: #{url}")
  end
end
```

### Rate Limiting

```ruby
processor :rate_limit do |url, output|
  @rate_limiter ||= RateLimiter.new(requests_per_second: 10)

  @rate_limiter.wait
  output << url
end
```

### Domain-Specific Crawling

```ruby
processor :filter_domain do |url, output|
  uri = URI.parse(url)
  allowed_domains = ['example.com', 'www.example.com']

  if allowed_domains.include?(uri.host)
    output << url
  end
end
```

### Extract Specific Data

```ruby
processor :extract_products do |parsed, output|
  doc = Nokogiri::HTML(parsed[:body])

  products = doc.css('.product').map do |product|
    {
      name: product.at_css('.name')&.text,
      price: product.at_css('.price')&.text,
      image: product.at_css('img')&.[]('src')
    }
  end

  output << { url: parsed[:url], products: products }
end
```

### Save to Database

```ruby
consumer :save_to_db do |parsed|
  Page.create!(
    url: parsed[:url],
    title: parsed[:title],
    content: parsed[:body],
    metadata: parsed[:meta],
    crawled_at: parsed[:fetched_at]
  )
end
```

### Export to JSON

```ruby
consumer :export do |parsed|
  File.open('crawl_results.jsonl', 'a') do |f|
    f.puts parsed.to_json
  end
end
```

## Advanced: Depth-Limited Crawling

Limit crawl depth to avoid going too deep:

```ruby
class DepthLimitedCrawler
  include Minigun::DSL

  def initialize(seed_urls, max_depth: 3)
    @seed_urls = seed_urls
    @max_depth = max_depth
  end

  pipeline do
    producer :seed do |output|
      @seed_urls.each { |url| output << { url: url, depth: 0 } }
    end

    processor :filter_depth do |item, output|
      if item[:depth] < @max_depth
        output << item
      end
    end

    processor :fetch, threads: 20 do |item, output|
      response = HTTP.get(item[:url])
      output << {
        url: item[:url],
        depth: item[:depth],
        body: response.body.to_s
      }
    end

    processor :extract_links do |page, output|
      links = extract_links(page[:body])

      links.each do |link|
        output.to(:filter_depth) << {
          url: link,
          depth: page[:depth] + 1
        }
      end
    end
  end
end
```

## Advanced: Polite Crawling

Implement per-domain rate limiting:

```ruby
class PoliteCrawler
  include Minigun::DSL

  def initialize
    @domain_limiters = Concurrent::Hash.new do |hash, domain|
      hash[domain] = RateLimiter.new(requests_per_second: 2)
    end
  end

  pipeline do
    processor :rate_limit do |url, output|
      domain = URI.parse(url).host
      @domain_limiters[domain].wait

      output << url
    end

    processor :fetch, threads: 20 do |url, output|
      # Fetch as before
    end
  end
end
```

## Error Handling

### Retry Failed Requests

```ruby
processor :fetch_with_retry, threads: 20 do |url, output|
  retries = 0
  max_retries = 3

  begin
    response = HTTP.timeout(10).get(url)
    output << { url: url, body: response.body.to_s }
  rescue HTTP::TimeoutError, HTTP::ConnectionError => e
    retries += 1
    if retries <= max_retries
      sleep 2 ** retries  # Exponential backoff
      retry
    else
      @errors << { url: url, error: "Failed after #{max_retries} retries" }
    end
  end
end
```

### Track Error Types

```ruby
def initialize
  @error_stats = Concurrent::Hash.new(0)
end

processor :fetch do |url, output|
  # ...
rescue HTTP::TimeoutError
  @error_stats[:timeout] += 1
rescue HTTP::ConnectionError
  @error_stats[:connection] += 1
rescue => e
  @error_stats[:other] += 1
end

# After crawl:
puts "Error breakdown:"
@error_stats.each { |type, count| puts "  #{type}: #{count}" }
```

## Performance Optimization

### Use HTTP Connection Pool

```ruby
def initialize
  @http_client = HTTP.persistent('https://example.com')
end

processor :fetch do |url, output|
  response = @http_client.get(url)
  # Connection reused across requests
end
```

### Compress Stored HTML

```ruby
require 'zlib'

consumer :store_compressed do |parsed|
  compressed = Zlib::Deflate.deflate(parsed[:body])

  File.write("pages/#{Digest::MD5.hexdigest(parsed[:url])}.gz", compressed)
end
```

### Use HUD to Find Bottlenecks

```ruby
require 'minigun/hud'

Minigun::HUD.run_with_hud(WebCrawler.new(seed_urls))
```

## Monitoring

### Progress Updates

```ruby
processor :report_progress do |parsed, output|
  @count ||= 0
  @mutex ||= Mutex.new

  @mutex.synchronize do
    @count += 1
    if @count % 10 == 0
      puts "Crawled #{@count} pages (#{@errors.size} errors)"
    end
  end

  output << parsed
end
```

### Live Statistics

```ruby
def stats
  {
    total: @results.size + @errors.size,
    success: @results.size,
    errors: @errors.size,
    success_rate: (@results.size.to_f / (@results.size + @errors.size) * 100).round(2)
  }
end
```

## Key Takeaways

- **High concurrency** for fetching (20+ threads for I/O)
- **Lower concurrency** for parsing (5 threads for CPU)
- **Feedback loops** with dynamic routing for recursive crawling
- **Thread-safe data structures** (Concurrent::Array, Concurrent::Set)
- **Graceful error handling** (capture errors, don't crash)
- **Rate limiting** to be a good internet citizen

## See Also

- [Tutorial: Concurrency](../tutorial/05_concurrency.md) - Thread safety
- [Routing Guide](../guides/routing/dynamic.md) - Dynamic routing
- [Example: Web Crawler](../../examples/10_web_crawler.rb) - Working example
- [Performance Tuning](../advanced/performance_tuning.md) - Optimization
