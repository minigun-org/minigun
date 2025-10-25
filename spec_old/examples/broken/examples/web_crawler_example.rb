# frozen_string_literal: true

require 'minigun'
require 'set'

class WebCrawlerExample
  include Minigun::DSL

  # Configuration
  max_threads 2
  max_processes 1
  batch_size 3

  attr_reader :visited_urls, :processed_pages, :start_url

  def initialize(start_url = 'https://example.com')
    @start_url = start_url
    @visited_urls = Set.new
    @processed_pages = 0

    puts "Web crawler initialized. Ready to crawl from #{start_url}"
  end

  # Pipeline definition for a web crawler
  pipeline do
    producer :seed_urls do
      puts "Starting crawl at #{context.start_url}"
      emit(context.start_url)
    end

    processor :fetch_url do |url|
      puts "Fetching URL: #{url}"

      # Simulate HTTP fetch
      # In a real crawler, you would use a library like net/http, httparty, or faraday
      content = simulate_fetch(url)

      emit({ url: url, content: content })
    end

    processor :extract_links do |page|
      puts "Extracting links from #{page[:url]}"

      # Extract links from content
      # In a real crawler, you would parse HTML with nokogiri or similar
      links = simulate_extract_links(page[:url], page[:content])

      puts "Found #{links.size} links on #{page[:url]}"

      # Forward the page for processing
      emit_to_queue(:process_page, page)

      # Forward each link for filtering
      links.each do |link|
        emit_to_queue(:filter_urls, link)
      end
    end

    processor :filter_urls, from: :extract_links, to: :fetch_url do |url|
      # Skip already visited URLs
      if context.visited_urls.include?(url)
        puts "Filtering out already visited URL: #{url}"
        return
      end

      # Apply URL filtering rules
      if should_crawl?(url)
        # Mark as visited to prevent loops
        context.visited_urls.add(url)
        puts "Accepted URL for crawling: #{url}"
        emit(url)
      else
        puts "Filtering out URL by rules: #{url}"
      end
    end

    processor :process_page, from: :extract_links, to: :store_content do |page|
      puts "Processing page: #{page[:url]}"

      # Simulate page processing
      # In a real crawler, you would extract text, metadata, etc.
      page[:title] = extract_title(page[:content])
      page[:word_count] = page[:content].split.size

      context.processed_pages += 1

      emit(page)
    end

    consumer :store_content, from: :process_page do |page|
      puts "Storing content for #{page[:url]}"
      puts "Title: #{page[:title]}"
      puts "Word count: #{page[:word_count]}"

      # Simulate storing to database or file
      puts "Page content stored. Total pages processed: #{context.processed_pages}"
    end
  end

  # Helper methods for simulation
  private

  def simulate_fetch(url)
    # Simulate fetching a page
    "This is simulated content for #{url}. It contains some sample text and links."
  end

  def simulate_extract_links(source_url, _content)
    # Simulate extracting links from HTML
    # Generate some plausible URLs based on the source URL
    domain = source_url.split('/')[2] || 'example.com'

    # Generate 2-4 random URLs
    links = []
    rand(2..4).times do |i|
      path = ['/page', '/article', '/product', '/category', '/about'].sample
      links << "https://#{domain}#{path}/#{i + 1}"
    end

    links
  end

  def extract_title(_content)
    # Simulate extracting title from content
    "Page about #{%w[technology business science health sports art].sample}"
  end

  def should_crawl?(url)
    # Filtering rules
    return false if url.include?('login') || url.include?('logout')
    return false if url.include?('admin') || url.include?('cart')

    # Limit crawl depth for testing
    return false if context.visited_urls.size >= 10

    true
  end

  before_run do
    puts 'Web crawler starting...'
  end

  after_run do
    puts "Web crawler finished. Processed #{processed_pages} pages and visited #{visited_urls.size} URLs."
  end
end

# Run the task if executed directly
WebCrawlerExample.new.run if __FILE__ == $PROGRAM_NAME
