# frozen_string_literal: true

require 'minigun'

class LoadBalancerExample
  include Minigun::DSL

  # Configuration
  max_threads 1
  max_processes 1

  # Pipeline definition for a load balancer
  pipeline do
    producer :request_generator do
      puts 'Generating HTTP requests...'

      # Generate 10 sample HTTP requests
      10.times do |i|
        request = {
          id: i + 1,
          method: %w[GET POST PUT].sample,
          path: ['/api/users', '/api/products', '/api/orders'].sample,
          params: { query: "request-#{i}" }
        }

        puts "Generated request #{request[:id]}: #{request[:method]} #{request[:path]}"
        emit(request)
      end
    end

    # Router that distributes requests to different servers
    processor :router do |request|
      # Simple round-robin load balancing
      server = case request[:id] % 3
               when 0 then :server_a
               when 1 then :server_b
               when 2 then :server_c
               end

      puts "Distributing request to server #{server}: #{request[:id]}"

      # Route to the appropriate server
      emit_to_queue(server, request)
    end

    # Three server processors for handling requests
    processor :server_a, from: :router, to: :response_collector do |request|
      puts "Server A processing request #{request[:id]}"

      # Simulate processing time
      response = {
        request_id: request[:id],
        server: 'A',
        status: 200,
        body: "Response from Server A for request #{request[:id]}"
      }

      emit(response)
    end

    processor :server_b, from: :router, to: :response_collector do |request|
      puts "Server B processing request #{request[:id]}"

      # Simulate processing time
      response = {
        request_id: request[:id],
        server: 'B',
        status: 200,
        body: "Response from Server B for request #{request[:id]}"
      }

      emit(response)
    end

    processor :server_c, from: :router, to: :response_collector do |request|
      puts "Server C processing request #{request[:id]}"

      # Simulate processing time
      response = {
        request_id: request[:id],
        server: 'C',
        status: 200,
        body: "Response from Server C for request #{request[:id]}"
      }

      emit(response)
    end

    # Collect and log all responses
    consumer :response_collector do |response|
      puts "Response collected from Server #{response[:server]} for request #{response[:request_id]}: status #{response[:status]}"
    end
  end

  before_run do
    puts 'Starting load balancer...'
  end

  after_run do
    puts 'Load balancer operations completed!'
  end
end

# Run the task if executed directly
LoadBalancerExample.new.run if __FILE__ == $PROGRAM_NAME
