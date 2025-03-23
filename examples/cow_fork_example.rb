# frozen_string_literal: true

require 'minigun'

class CowForkExample
  include Minigun::DSL

  # Configuration
  max_threads 2
  max_processes 2
  batch_size 2
  consumer_type :cow

  # Hook examples
  before_fork do
    puts 'Preparing to fork process...'
  end

  after_fork do
    puts 'Process forked successfully.'
  end

  # Pipeline definition
  pipeline do
    producer :generate_data do
      puts 'Generating data...'
      10.times do |i|
        item = i + 1
        emit(item)
      end
    end

    accumulator :batch_items do |item|
      @items ||= []
      @items << item

      if @items.size >= batch_size
        puts "Generating batch of #{@items.size} items"
        batch = @items.dup
        @items.clear
        emit(batch)
      end
    end

    cow_fork :process_batch do |batch|
      puts "Processing batch of #{batch.size} items"
      puts "Items: #{batch.join(', ')}"

      sum = batch.sum
      avg = sum / batch.size.to_f

      puts "Batch sum: #{sum}, average: #{avg}"
    end
  end

  after_run do
    puts 'Processing complete: all batches processed'
  end
end

# Run the task if executed directly
CowForkExample.new.run if __FILE__ == $PROGRAM_NAME
