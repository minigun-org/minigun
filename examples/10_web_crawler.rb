#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

# Web Crawler Example
# Demonstrates a multi-stage web crawler pipeline
class WebCrawler
  include Minigun::DSL

  max_threads 20  # High concurrency for I/O-bound web fetching

  attr_accessor :pages_fetched, :links_extracted, :pages_processed

  def initialize(seed_urls)
    @seed_urls = seed_urls
    @pages_fetched = []
    @links_extracted = []
    @pages_processed = []
    @mutex = Mutex.new
  end

  # Simulate fetching a web page
  def fetch_page(url)
    puts "[Fetch] Fetching #{url}"
    # In a real crawler, this would use Net::HTTP or similar
    sleep 0.1  # Simulate network delay
    {
      url: url,
      title: "Page: #{url}",
      content: "Content from #{url} with some text...",
      status: 200
    }
  end

  # Extract links from page content
  def extract_links(content)
    # In a real crawler, this would parse HTML and extract <a> tags
    # For demo, just generate some fake links
    links = []
    if content.include?('example.com')
      links << 'http://example.com/about'
      links << 'http://example.com/contact'
    elsif content.include?('test.com')
      links << 'http://test.com/page1'
      links << 'http://test.com/page2'
    end
    links
  end

  # Save page data
  def save_page(page)
    puts "[Save] Storing #{page[:url]} (#{page[:title]})"
    # In a real crawler, this would save to database or file
  end

  pipeline do
    # Stage 1: Seed with initial URLs
    producer :seed_urls do
      @seed_urls.each { |url| emit(url) }
      puts "[Seed] Emitted #{@seed_urls.size} seed URLs"
    end

    # Stage 2: Fetch pages from URLs
    processor :fetch_pages do |url|
      page = fetch_page(url)
      @mutex.synchronize { pages_fetched << page }
      emit(page)
    end

    # Stage 3: Extract links from fetched pages
    processor :extract_links do |page|
      links = extract_links(page[:content])
      @mutex.synchronize { links_extracted.concat(links) }
      
      puts "[Extract] Found #{links.size} links on #{page[:url]}"
      
      # Emit the page for further processing
      emit(page)
      
      # Could emit links here to crawl them (would create a loop)
      # For this demo, we just extract and log them
    end

    # Stage 4: Process and store pages
    consumer :process_pages do |page|
      @mutex.synchronize { pages_processed << page }
      save_page(page)
    end
  end
end

if __FILE__ == $0
  puts "=== Web Crawler Example ===\n\n"

  seed_urls = [
    'http://example.com',
    'http://example.com/products',
    'http://test.com',
    'http://test.com/services',
    'http://another-site.com'
  ]

  crawler = WebCrawler.new(seed_urls)
  
  puts "Starting crawl with #{seed_urls.size} seed URLs\n"
  puts "Max threads: 20 (for concurrent fetching)\n\n"
  
  crawler.run

  puts "\n=== Crawl Results ===\n"
  puts "Pages fetched: #{crawler.pages_fetched.size}"
  puts "Links extracted: #{crawler.links_extracted.size}"
  puts "Pages processed: #{crawler.pages_processed.size}"
  
  puts "\nFetched URLs:"
  crawler.pages_fetched.each do |page|
    puts "  - #{page[:url]} (#{page[:status]})"
  end
  
  puts "\nExtracted Links:"
  crawler.links_extracted.each do |link|
    puts "  - #{link}"
  end
  
  puts "\n✓ Crawl complete!"
end

