# frozen_string_literal: true

require_relative '../lib/minigun'

# Load Balancer Pattern
# Demonstrates distributing work across multiple workers/servers
class LoadBalancerExample
  include Minigun::DSL

  attr_reader :server_stats

  def initialize
    @server_stats = Hash.new { |h, k| h[k] = { requests: 0, total_time: 0 } }
    @mutex = Mutex.new
  end

  pipeline do
    producer :request_generator do |output|
      puts "\n#{'=' * 60}"
      puts 'LOAD BALANCER: Generating HTTP Requests'
      puts '=' * 60

      # Generate 15 sample HTTP requests
      15.times do |i|
        request = {
          id: i + 1,
          method: %w[GET POST PUT DELETE].sample,
          path: ['/api/users', '/api/products', '/api/orders', '/health'].sample,
          params: { query: "request-#{i}" },
          timestamp: Time.now.to_i
        }

        puts "Generated request #{request[:id]}: #{request[:method]} #{request[:path]}"
        output << request
      end
    end

    # Round-robin router distributes to three servers
    processor :router do |request, output|
      # Simple round-robin load balancing
      server_id = (request[:id] - 1) % 3
      request[:assigned_server] = server_id

      puts "→ Routing request #{request[:id]} to server #{server_id}"
      output << request
    end

    # Simulate three server processors with different speeds
    thread_pool(3) do
      processor :process_request do |request, output|
        server_id = request[:assigned_server]
        server_name = "Server-#{server_id}"

        # Each server has slightly different processing time
        processing_time = (0.01 + (server_id * 0.005))
        sleep(processing_time)

        @mutex.synchronize do
          @server_stats[server_id][:requests] += 1
          @server_stats[server_id][:total_time] += processing_time
        end

        response = {
          request_id: request[:id],
          server: server_name,
          status: [200, 200, 200, 500].sample, # Occasional error
          processing_time: processing_time,
          body: "Response from #{server_name}"
        }

        puts "  #{server_name} processed request #{request[:id]} (#{response[:status]}) in #{processing_time.round(3)}s"
        output << response
      end
    end

    # Collect responses and track metrics
    consumer :response_collector do |response|
      status_emoji = response[:status] == 200 ? '✓' : '✗'
      puts "#{status_emoji} Response received from #{response[:server]}: request #{response[:request_id]} [#{response[:status]}]"
    end

    after_run do
      puts "\n#{'=' * 60}"
      puts 'LOAD BALANCER STATISTICS'
      puts '=' * 60

      @server_stats.sort.each do |server_id, stats|
        avg_time = (stats[:total_time] / stats[:requests]).round(3)
        puts "Server-#{server_id}: #{stats[:requests]} requests, avg time: #{avg_time}s"
      end

      puts "\nLoad balancing complete!"
      puts '=' * 60
    end
  end
end

# Run if executed directly
LoadBalancerExample.new.run if __FILE__ == $PROGRAM_NAME
