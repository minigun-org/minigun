#!/usr/bin/env ruby
# frozen_string_literal: true

# Example 33: Threads Block - Basic Thread Pool Usage
#
# Demonstrates using threads(N) to create a thread pool for I/O-bound work

require_relative '../lib/minigun'

puts "=" * 60
puts "threads(N) Block - Thread Pool Execution"
puts "=" * 60

class WebScraper
  include Minigun::DSL
  
  attr_reader :pages
  
  def initialize
    @pages = []
    @mutex = Mutex.new
  end
  
  pipeline do
    producer :generate_urls do
      20.times { |i| emit("https://example.com/page-#{i}") }
    end
    
    # All stages in this block use a pool of 10 threads
    threads(10) do
      processor :download do |url|
        # Simulate HTTP request
        sleep 0.01
        emit({ url: url, html: "<html>...</html>", fetched_at: Time.now })
      end
      
      processor :extract_links do |page|
        # Extract data
        emit({ url: page[:url], links: 5, title: "Page" })
      end
      
      consumer :store do |page|
        @mutex.synchronize { @pages << page }
      end
    end
  end
end

scraper = WebScraper.new
scraper.run

puts "\nResults:"
puts "  Downloaded: #{scraper.pages.size} pages"
puts "  Total links: #{scraper.pages.sum { |p| p[:links] }}"
puts "\n✓ All stages executed in shared thread pool of 10"
puts "✓ Efficient for I/O-bound work"
puts "✓ Threads reused across stages"

