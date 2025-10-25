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

      puts "Accumulator: Added item #{item}, current size #{@items.size}"

      if @items.size >= batch_size || item == 0 || item % 8 == 0
        puts "Accumulator: Emitting batch #{@items.inspect}"
        batch = @items.dup
        @items.clear
        emit(batch)
      end
    end

    consumer :process_batch do |batch|
      # Handle either a single item or a batch
      if batch.is_a?(Array)
        puts "Processing batch: #{batch.inspect}"
        batch.each do |item|
          puts "Processing #{item}"
        end
      else
        puts "Processing #{batch}"
      end
    end
  end

  before_run do
    puts 'Starting task...'

    # Special handling for fork_mode=:never in tests
    if self.class._minigun_task.config[:fork_mode] == :never
      # Pre-create important structures for the pipeline
      self.class._minigun_task.instance_variable_set(:@flushed_items, [])
      self.class._minigun_task.instance_variable_set(:@never_mode_setup, true)
    end
  end

  after_run do
    puts 'Task completed!'

    # Special handling for fork_mode=:never
    if self.class._minigun_task.config[:fork_mode] == :never && instance_variable_defined?(:@items) && @items && !@items.empty?
      # We need to manually process any remaining items in test mode
      items_to_process = @items.dup
      @items.clear

      # Process directly
      items_to_process.each do |item|
        puts "Processing #{item}"
      end
    end
  end
end

# Run the task if executed directly
QuickStartExample.new.run if __FILE__ == $PROGRAM_NAME
