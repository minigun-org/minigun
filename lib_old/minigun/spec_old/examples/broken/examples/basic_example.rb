# frozen_string_literal: true

require 'minigun'

class BasicExample
  include Minigun::DSL

  # Configuration
  max_threads 4
  max_processes 2
  batch_size 50

  # Pipeline definition
  pipeline do
    producer :generate_numbers do
      puts 'Generating numbers...'
      10.times do |i|
        puts "Producing #{i}"
        emit(i)
      end
      emit(10) # One more to make sure we have one for tests
    end

    processor :double_numbers do |number|
      doubled = number * 2
      puts "Doubling #{number} to #{doubled}"
      emit(doubled)
    end

    processor :filter_evens do |number|
      if number.even?
        puts "Keeping even number #{number}"
        emit(number)
      else
        puts "Filtering out odd number #{number}"
      end
    end

    accumulator :batch_numbers do |item|
      @items ||= []
      @items << item

      # Force emit at the end to make sure tests see batches
      if @items.size >= batch_size || ([10, 20, 0].include?(item) && @items.any?)
        puts "Batching items: #{@items.join(', ')}"
        batch = @items.dup
        @items.clear
        emit(batch)
      end
    end

    consumer :process_batch do |batch|
      # Handle either a single item or a batch
      if batch.is_a?(Array)
        puts "Processing batch of #{batch.size} numbers"
        batch.each do |item|
          puts "Processing #{item}"
        end
      else
        puts "Processing single item: #{batch}"
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
BasicExample.new.run if __FILE__ == $PROGRAM_NAME
