# frozen_string_literal: true

require 'minigun'

class ExplicitConnectionExample
  include Minigun::DSL

  # Configuration
  max_threads 1
  max_processes 1

  # Pipeline definition with explicit connections
  pipeline do
    producer :producer do
      puts 'Producing items...'
      5.times do |i|
        item = { id: i + 1, data: "item-#{i + 1}" }
        puts "Producing item #{item[:id]}"
        emit(item)
      end
    end

    # Explicit connection to 'validator' instead of next stage in sequence
    processor :processor, to: :validator do |item|
      puts "Processing item #{item[:id]}"
      item[:processed] = true
      item[:value] = item[:id] * 10
      emit(item)
    end

    # Validating items
    processor :validator do |item|
      puts "Validating item #{item[:id]}"

      if item[:processed] && item[:value] >= 10
        puts "Item #{item[:id]} is valid"
        emit(item)
      else
        puts "Item #{item[:id]} is invalid"
      end
    end

    # Final consumer
    consumer :consumer do |item|
      puts "Consuming valid item #{item[:id]} with value #{item[:value]}"
    end
  end

  before_run do
    puts 'Starting explicit connection pipeline...'
  end

  after_run do
    puts 'Explicit connection pipeline completed!'
  end
end

# Run the task if executed directly
ExplicitConnectionExample.new.run if __FILE__ == $PROGRAM_NAME
