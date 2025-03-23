# frozen_string_literal: true

require 'minigun'

class IpcForkExample
  include Minigun::DSL

  # Configuration
  max_threads 2
  max_processes 2
  batch_size 3
  consumer_type :ipc

  # Hook examples
  before_fork do
    puts 'Preparing to fork IPC process...'
  end

  after_fork do
    puts 'IPC process forked successfully.'
  end

  # Pipeline definition
  pipeline do
    producer :generate_data do
      puts 'Generating IPC data...'
      15.times do |i|
        item = i + 1
        emit(item)
      end
    end

    accumulator :batch_items do |item|
      @items ||= []
      @items << item

      if @items.size >= 3 # Fixed batch size value to match class configuration
        puts "Generating IPC batch of #{@items.size} items"
        batch = @items.dup
        @items.clear
        emit(batch)
      end
    end

    ipc_fork :process_batch do |batch|
      puts "Processing IPC batch of #{batch.size} items"
      puts "Items: #{batch.join(', ')}"

      sum = batch.sum
      avg = sum / batch.size.to_f

      puts "Batch sum: #{sum}, average: #{avg}"

      # Return a hash of results that will be transported back to parent
      { sum: sum, average: avg, count: batch.size }
    end

    processor :verify_results do |result|
      puts "Verifying results: sum=#{result[:sum]}, average=#{result[:average]}, count=#{result[:count]}"
      # You could add validation logic here
      emit(result)
    end
  end

  after_run do
    puts 'IPC processing complete: all batches processed'
  end
end

# Run the task if executed directly
IpcForkExample.new.run if __FILE__ == $PROGRAM_NAME
