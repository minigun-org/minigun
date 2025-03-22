# frozen_string_literal: true

require 'minigun'

# Example task using Minigun DSL
class BasicTask
  include Minigun::DSL

  # Configure the task
  max_threads 4
  max_processes 2
  batch_size 50

  # Define hooks
  before_run do
    puts 'Starting task...'
  end

  after_run do
    puts 'Task completed!'
  end

  # Define a pipeline
  pipeline do
    # Generate numbers 1-100
    producer :generate_numbers do
      100.times { |i| produce(i + 1) }
    end

    # Double each number
    processor :double_numbers do |num|
      emit(num * 2)
    end

    # Filter for even numbers
    processor :filter_evens do |num|
      emit(num) if num.even?
    end

    # Batch numbers for processing
    accumulator :batch_numbers do |num|
      accumulate(num, key: :numbers)
    end

    # Process the batches
    consumer :process_batch do |batch|
      puts "Processing batch of #{batch.size} numbers: #{batch.join(', ')}"
    end
  end
end

# Run the task
BasicTask.new.run if __FILE__ == $PROGRAM_NAME
