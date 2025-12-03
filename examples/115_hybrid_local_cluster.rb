#!/usr/bin/env ruby
# frozen_string_literal: true

# Example: Hybrid Local + Cluster Pipeline
#
# Demonstrates mixing local execution (threads/forks) with cluster execution
# in a single pipeline. Use local for I/O-bound, cluster for CPU-bound.
#
# Topology:
#
#   Producer (local threads)
#        ↓
#   Fetch URLs (local thread pool - I/O bound)
#        ↓
#   Parse HTML (cluster - CPU bound)
#        ↓
#   Extract Data (local forks - CPU bound but small)
#        ↓
#   Save Results (local threads - I/O bound)
#
# This demonstrates when to use each execution strategy:
# - Local threads: I/O-bound tasks (network, disk)
# - Local forks: CPU-bound tasks (small scale)
# - Cluster: CPU-bound tasks (large scale, multiple machines)
#
# Usage:
#   Terminal 1: ruby examples/115_hybrid_local_cluster.rb coordinator
#   Terminal 2-4: ruby examples/115_hybrid_local_cluster.rb worker (multiple)

require_relative '../lib/minigun'

# Force unbuffered output for test harness compatibility
$stdout.sync = true
$stderr.sync = true

# Configuration via environment variables for testing
CLUSTER_PORT = ENV.fetch('CLUSTER_PORT', '9000').to_i
WORKER_TIMEOUT = ENV.fetch('WORKER_TIMEOUT', '30').to_i

# Hybrid pipeline mixing local and cluster execution strategies
class HybridPipeline
  def self.create_pipeline(port)
    Class.new do
      include Minigun::DSL

      attr_reader :results

      define_method(:initialize) do
        @results = []
      end

      pipeline do
        # Local producer (sequential, runs on coordinator)
        producer :generate_urls do |output|
          puts '[Producer] Generating URLs to process...'
          20.times do |i|
            output << { id: i, url: "https://example.com/page-#{i}" }
          end
          puts '[Producer] Generated 20 URLs'
        end

        # Local thread pool: Fetch URLs (I/O-bound, benefits from threads)
        in_threads(5) do
          processor :fetch do |item, output|
            puts "  [Fetch Thread] Fetching #{item[:url]}..."
            sleep 0.05 # Simulate network I/O
            html = "<html><body>Content for page #{item[:id]}</body></html>"
            output << { id: item[:id], url: item[:url], html: html, size: html.length }
          end
        end

        # Cluster: Parse HTML (CPU-bound, distribute across machines)
        in_cluster(coordinator_uri: "druby://0.0.0.0:#{port}", min_workers: 2, worker_timeout: WORKER_TIMEOUT) do
          processor :parse_html do |item, output|
            puts "  [Parse Cluster] Parsing HTML for page #{item[:id]}..."
            sleep 0.15 # Simulate CPU-intensive parsing
            # Extract links, text, metadata, etc.
            parsed = {
              id: item[:id],
              url: item[:url],
              links: (1..5).map { |i| "link-#{i}" },
              words: item[:html].split.size,
              metadata: { size: item[:size], timestamp: Time.now.to_i }
            }
            output << parsed
          end
        end

        # Local forks: Extract specific data (CPU-bound but lightweight)
        in_cow_forks(3) do
          processor :extract_data do |item, output|
            puts "  [Extract Fork] Extracting data from page #{item[:id]}..."
            # Simulate data extraction
            extracted = {
              id: item[:id],
              url: item[:url],
              link_count: item[:links].size,
              word_count: item[:words],
              summary: "Page #{item[:id]} has #{item[:links].size} links"
            }
            output << extracted
          end
        end

        # Local thread pool: Save results (I/O-bound database/disk writes)
        in_threads(3) do
          processor :save do |item, output|
            puts "  [Save Thread] Saving result for page #{item[:id]}..."
            sleep 0.03 # Simulate database write
            saved = item.merge(saved_at: Time.now.to_i, status: 'saved')
            output << saved
          end
        end

        # Local consumer: Collect final results
        consumer :collect do |item|
          @results << item
        end
      end
    end.new
  end
end

# Cluster worker for HTML parsing
def run_parse_worker(port = CLUSTER_PORT)
  worker = Minigun::Cluster::Worker.new(
    coordinator_uri: "druby://127.0.0.1:#{port}",
    worker_id: "parse-worker-#{Process.pid}"
  )

  worker.register_stage(:parse_html) do |item, output|
    puts "  [Parse Worker #{Process.pid}] Parsing page #{item[:id]}..."
    sleep 0.15 # Simulate CPU-intensive parsing
    parsed = {
      id: item[:id],
      url: item[:url],
      links: (1..5).map { |i| "link-#{i}" },
      words: item[:html].split.size,
      metadata: { size: item[:size], timestamp: Time.now.to_i }
    }
    output.call(parsed)
  end

  worker.connect
  puts "Parse worker #{worker.worker_id} connected!"
  worker.start
end

# Main execution
if __FILE__ == $PROGRAM_NAME
  Minigun.logger.level = Logger::INFO

  mode = ARGV[0] || 'coordinator'

  case mode
  when 'coordinator'
    puts '=== Hybrid Local + Cluster Pipeline ==='
    puts
    puts 'This pipeline demonstrates optimal execution strategy choices:'
    puts '  1. Generate URLs     → Local (sequential)'
    puts '  2. Fetch URLs        → Local threads (I/O-bound)'
    puts '  3. Parse HTML        → Cluster (CPU-bound, distributable)'
    puts '  4. Extract Data      → Local forks (CPU-bound, small)'
    puts '  5. Save Results      → Local threads (I/O-bound)'
    puts
    puts 'Start cluster workers in separate terminals:'
    puts '  ruby examples/115_hybrid_local_cluster.rb worker'
    puts '  ruby examples/115_hybrid_local_cluster.rb worker'
    puts

    pipeline = HybridPipeline.create_pipeline(CLUSTER_PORT)

    start_time = Time.now
    pipeline.run
    elapsed = Time.now - start_time

    puts
    puts '=== Results Summary ==='
    puts "Total pages processed: #{pipeline.results.size}"
    puts "Elapsed time: #{elapsed.round(2)}s"
    puts
    puts 'Sample results:'
    pipeline.results.first(3).each do |r|
      puts "  Page #{r[:id]}: #{r[:link_count]} links, #{r[:word_count]} words - #{r[:summary]}"
    end

    puts
    puts '=== Performance Breakdown ==='
    puts 'Estimated time if all local sequential:'
    sequential_time = 20 * (0.05 + 0.15 + 0.05 + 0.03)
    puts "  #{sequential_time.round(2)}s (20 items × 0.28s each)"
    puts
    puts 'Actual time with hybrid approach:'
    puts "  #{elapsed.round(2)}s"
    puts
    speedup = sequential_time / elapsed
    puts "Speedup: #{speedup.round(2)}x"

  when 'worker'
    puts '=== Cluster Worker (HTML Parser) ==='
    run_parse_worker(CLUSTER_PORT)

  else
    puts "Unknown mode: #{mode}"
    puts 'Usage: ruby examples/115_hybrid_local_cluster.rb [coordinator|worker]'
    exit 1
  end
end
