# frozen_string_literal: true

require 'minigun'

class DiamondShapedExample
  include Minigun::DSL

  # Configuration
  max_threads 1
  max_processes 1
  batch_size 1

  # Pipeline definition with a diamond shape pattern:
  # producer → branch_a → merge → consumer
  #         → branch_b ↗
  #         → branch_c ↗
  pipeline do
    producer :producer do
      puts 'Producing items...'
      5.times do |i|
        item = i + 1
        puts "Producing item #{item}"
        emit(item)
      end
    end

    # Three parallel branches
    processor :branch_a, to: :merge do |item|
      processed = item * 2
      puts "Branch A: #{item} -> #{processed}"
      emit({ branch: 'A', value: processed })
    end

    processor :branch_b, to: :merge do |item|
      processed = item + 10
      puts "Branch B: #{item} -> #{processed}"
      emit({ branch: 'B', value: processed })
    end

    processor :branch_c, to: :merge do |item|
      processed = item**2
      puts "Branch C: #{item} -> #{processed}"
      emit({ branch: 'C', value: processed })
    end

    # Merge point that collects results from all branches
    processor :merge do |item|
      puts "Merge received: #{item[:branch]} = #{item[:value]}"

      # Simply pass the processed items to the consumer
      emit(item)
    end

    # Final consumer
    consumer :consumer do |item|
      puts "Consuming result from branch #{item[:branch]}: #{item[:value]}"
    end
  end

  before_run do
    puts 'Starting diamond-shaped pipeline...'
  end

  after_run do
    puts 'Diamond-shaped pipeline completed!'
  end
end

# Run the task if executed directly
DiamondShapedExample.new.run if __FILE__ == $PROGRAM_NAME
