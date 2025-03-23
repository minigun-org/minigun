# frozen_string_literal: true

require 'minigun'

class QuickStartExample
  include Minigun::DSL

  # Configuration
  max_threads 1
  max_processes 1
  batch_size 3

  # Pipeline definition
  pipeline do
    producer :generate do
      puts 'Generating numbers...'
      10.times do |i|
        puts "Producing #{i}"
        emit(i)
      end
    end

    processor :transform do |number|
      transformed = number * 2
      puts "Transforming #{number} to #{transformed}"
      emit(transformed)
    end

    accumulator :batch do |item|
      @items ||= []
      @items << item

      if @items.size >= batch_size
        puts "Batching items: #{@items.join(', ')}"
        batch = @items.dup
        @items.clear
        emit(batch)
      end
    end

    consumer :process_batch do |batch|
      puts "Processing batch: #{batch.inspect}"
      batch.each do |item|
        puts "Processing #{item}"
      end
    end
  end

  before_run do
    puts 'Starting task...'
  end

  after_run do
    puts 'Task completed!'
  end
end

# Run the task if executed directly
QuickStartExample.new.run if __FILE__ == $PROGRAM_NAME
