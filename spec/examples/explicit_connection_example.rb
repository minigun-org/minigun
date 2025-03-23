# frozen_string_literal: true

require 'minigun'

class ExplicitConnectionExample
  include Minigun::DSL

  pipeline do
    # Sequential connection
    producer :source do
      10.times { |i| emit(i) }
    end

    processor :first_stage do |item|
      emit(item + 1)
    end

    processor :second_stage do |item|
      emit(item * 2)
    end

    # Explicit connections
    processor :stage_a, to: %i[stage_b stage_c] do |item|
      emit(item)
    end

    processor :stage_b, from: :stage_a do |item|
      # Process items from stage_a
      puts "Stage B received: #{item}"
      emit("B: #{item}")
    end

    processor :stage_c, from: :stage_a do |item|
      # Also process items from stage_a
      puts "Stage C received: #{item}"
      emit("C: #{item}")
    end

    consumer :output, from: %i[stage_b stage_c second_stage] do |item|
      puts "Final output: #{item}"
    end
  end
end

# Run the task
ExplicitConnectionsExample.new.run if __FILE__ == $PROGRAM_NAME
