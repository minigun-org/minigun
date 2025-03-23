# frozen_string_literal: true

require 'minigun'

class LoadBalancerExample
  include Minigun::DSL

  pipeline do
    producer :data_source do
      # Sample large dataset
      large_dataset = (1..20).map { |i| { id: i, value: "Value #{i}" } }

      large_dataset.each_with_index do |item, i|
        # Round-robin distribute across multiple queues
        queue = %i[queue_1 queue_2 queue_3][i % 3]
        puts "Routing item #{item[:id]} to #{queue}"
        emit_to_queue(queue, item)
      end
    end

    # Process queue 1 with specific settings
    processor :worker_1, queues: [:queue_1], threads: 3 do |item|
      puts "Worker 1 (3 threads) processing item #{item[:id]}"
      result = process_with_worker_1(item)
      emit(result)
    end

    # Process queue 2 with different settings
    processor :worker_2, queues: [:queue_2], threads: 5 do |item|
      puts "Worker 2 (5 threads) processing item #{item[:id]}"
      result = process_with_worker_2(item)
      emit(result)
    end

    # Process queue 3 with yet different settings
    processor :worker_3, queues: [:queue_3], threads: 2 do |item|
      puts "Worker 3 (2 threads) processing item #{item[:id]}"
      result = process_with_worker_3(item)
      emit(result)
    end

    # All results go to the same accumulator
    accumulator :result_collector, from: %i[worker_1 worker_2 worker_3] do |result|
      @results ||= []
      @results << result

      if @results.size >= 5 # Using 5 instead of 100 for the example
        batch = @results.dup
        @results.clear
        emit(batch)
      end
    end

    consumer :store_results, from: :result_collector do |batch|
      puts "Storing batch of #{batch.size} results"
      batch.each { |result| puts "  Stored: #{result[:id]} - #{result[:processed_by]}" }
    end
  end

  private

  def process_with_worker_1(item)
    { id: item[:id], value: item[:value], processed_by: 'Worker 1' }
  end

  def process_with_worker_2(item)
    { id: item[:id], value: item[:value], processed_by: 'Worker 2' }
  end

  def process_with_worker_3(item)
    { id: item[:id], value: item[:value], processed_by: 'Worker 3' }
  end
end

# Run the task
LoadBalancingExample.new.run if __FILE__ == $PROGRAM_NAME
