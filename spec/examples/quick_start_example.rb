# frozen_string_literal: true

require 'minigun'

class QuickStartExample
  include Minigun::DSL

  pipeline do
    producer :generate do
      10.times { |i| emit(i) }
    end

    processor :transform do |number|
      emit(number * 2)
    end

    accumulator :batch do |item|
      @items ||= []
      @items << item

      if @items.size >= 5
        batch = @items.dup
        @items.clear
        emit(batch)
      end
    end

    cow_fork :process_batch do |batch|
      # Process the batch in a forked child process
      batch.each { |item| puts "Processing #{item}" }
    end
  end
end

# Run the task
MyTask.new.run if __FILE__ == $PROGRAM_NAME
