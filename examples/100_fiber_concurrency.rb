#!/usr/bin/env ruby
# frozen_string_literal: true

# Example 80: Fiber Concurrency - Using async gem for lightweight concurrency
#
# Fibers are lightweight (~4KB) compared to threads (~1MB).
# They use cooperative scheduling - yielding automatically on I/O operations.
# Best for I/O-bound workloads like HTTP requests, database queries, file I/O.
#
# REQUIREMENT: Add `gem 'async'` to your Gemfile

require_relative '../lib/minigun'

puts '=' * 60
puts 'Fiber Concurrency with async gem'
puts '=' * 60

unless Minigun::Platform.fibers?
  puts "\n⚠️  The 'async' gem is not installed."
  puts "   Add `gem 'async'` to your Gemfile and run `bundle install`"
  exit 1
end

# Demonstrates fiber pools for I/O-bound work
class FiberWebScraper
  include Minigun::DSL

  attr_reader :pages

  def initialize
    @pages = []
    @mutex = Mutex.new
  end

  pipeline do
    producer :generate_urls do |output|
      30.times { |i| output << "https://example.com/page-#{i}" }
    end

    # All stages in this block use a pool of 10 fibers
    # Fibers yield automatically on sleep/IO, allowing others to run
    in_fibers(10) do
      processor :download do |url, output|
        # Simulate HTTP request - fibers yield during sleep
        sleep 0.02
        output << { url: url, html: '<html>...</html>', fetched_at: Time.now }
      end

      processor :extract_links do |page, output|
        # Simulate parsing - another yield point
        sleep 0.01
        output << { url: page[:url], links: rand(1..10), title: 'Page' }
      end

      consumer :store do |page|
        @mutex.synchronize { @pages << page }
      end
    end
  end
end

puts "\nRunning fiber-based web scraper..."
puts "Processing 30 URLs with 10 concurrent fibers\n"

start_time = Time.now
scraper = FiberWebScraper.new
scraper.run
elapsed = Time.now - start_time

puts "\nResults:"
puts "  Downloaded: #{scraper.pages.size} pages"
puts "  Total links: #{scraper.pages.sum { |p| p[:links] }}"
puts "  Elapsed: #{elapsed.round(2)}s"
puts "\n✓ Fibers are lightweight (~4KB each vs ~1MB for threads)"
puts '✓ Cooperative scheduling - yield on I/O automatically'
puts '✓ Best for I/O-bound work (HTTP, DB, files)'
puts '✓ All fibers run in a single thread (no GIL contention)'

puts "\n#{'=' * 60}"
puts 'Comparing Fibers vs Threads'
puts '=' * 60

# Compare with threads
class ThreadWebScraper
  include Minigun::DSL

  attr_reader :pages

  def initialize
    @pages = []
    @mutex = Mutex.new
  end

  pipeline do
    producer :generate_urls do |output|
      30.times { |i| output << "https://example.com/page-#{i}" }
    end

    in_threads(10) do
      processor :download do |url, output|
        sleep 0.02
        output << { url: url, html: '<html>...</html>', fetched_at: Time.now }
      end

      processor :extract_links do |page, output|
        sleep 0.01
        output << { url: page[:url], links: rand(1..10), title: 'Page' }
      end

      consumer :store do |page|
        @mutex.synchronize { @pages << page }
      end
    end
  end
end

puts "\nRunning thread-based scraper for comparison..."
thread_start = Time.now
thread_scraper = ThreadWebScraper.new
thread_scraper.run
thread_elapsed = Time.now - thread_start

puts "\nComparison:"
puts "  Fibers:  #{elapsed.round(2)}s (#{scraper.pages.size} pages)"
puts "  Threads: #{thread_elapsed.round(2)}s (#{thread_scraper.pages.size} pages)"
puts "\n💡 For I/O-bound work, fibers offer similar performance with lower memory"
