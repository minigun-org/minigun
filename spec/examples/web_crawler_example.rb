# frozen_string_literal: true

require 'minigun'

class WebCrawlerExample
  include Minigun::DSL

  max_threads 20

  pipeline do
    producer :seed_urls do
      initial_urls = [
        'https://example.com',
        'https://example.org',
        'https://example.net'
      ]

      initial_urls.each do |url|
        puts "Seeding URL: #{url}"
        emit(url)
      end
    end

    processor :fetch_pages do |url|
      puts "Fetching page: #{url}"

      # Simulate HTTP response
      content = "
        <html>
          <body>
            <a href='https://example.com/page1'>Link 1</a>
            <a href='https://example.com/page2'>Link 2</a>
            <a href='https://example.org/page3'>Link 3</a>
            <div>Sample content for #{url}</div>
          </body>
        </html>
      "

      { url: url, content: content }
    end

    processor :extract_links do |page|
      puts "Extracting links from: #{page[:url]}"

      # Extract links from HTML (simplified for example)
      links = extract_links_from_html(page[:content])

      # Emit new links for crawling
      links.each do |link|
        puts "  Found link: #{link}"
        emit(link)
      end

      # Pass the page content for processing
      emit(page)
    end

    accumulator :batch_pages do |page|
      @pages ||= []
      @pages << page

      if @pages.size >= 2 # Using 2 instead of 10 for the example
        batch = @pages.dup
        @pages.clear
        emit(batch)
      end
    end

    cow_fork :process_pages do |batch|
      # Process pages in parallel using forked processes
      puts "Processing batch of #{batch.size} pages in forked process"

      batch.each do |page|
        process_content(page)
      end
    end
  end

  private

  def extract_links_from_html(html)
    # Simplified link extraction with regex
    html.scan(/<a href='([^']+)'/).flatten.uniq
  end

  def process_content(page)
    puts "Processing content from #{page[:url]}"
    # Simulate content processing
    puts "  Found content: #{page[:content].gsub(/<[^>]+>/, '').strip[0..50]}..."
  end
end

# Run the task
WebCrawler.new.run if __FILE__ == $PROGRAM_NAME
