# frozen_string_literal: true

require 'minigun'

class HooksExample
  include Minigun::DSL

  # Configuration
  max_threads 1
  max_processes 1

  # Define hooks that run at different points in the task lifecycle
  before_run do
    puts 'HOOK: Before run - Initializing task resources'
    @start_time = Time.now
  end

  after_run do
    duration = Time.now - @start_time
    puts "HOOK: After run - Task completed in #{duration.round(1)} seconds"
  end

  before_stage :producer do
    puts 'HOOK: Before producer - Setting up data source'
  end

  after_stage :producer do
    puts 'HOOK: After producer - Data source closed'
  end

  before_stage :processor do
    puts 'HOOK: Before processor - Setting up processing environment'
  end

  after_stage :processor do
    puts 'HOOK: After processor - Processing environment cleaned up'
  end

  before_stage :consumer do
    puts 'HOOK: Before consumer - Setting up output destination'
  end

  after_stage :consumer do
    puts 'HOOK: After consumer - Output destination closed'
  end

  on_stage_error :processor do |error|
    puts "HOOK: Error in processor stage: #{error.message}"
    puts 'HOOK: Attempting to recover...'
  end

  # Pipeline definition with hooks
  pipeline do
    producer :producer do
      puts 'Producer stage: Generating data'
      5.times do |i|
        item = i + 1
        puts "Producer: Generated item #{item}"
        emit(item)
      end
    end

    processor :processor do |item|
      puts "Processor stage: Processing item #{item}"

      # Intentionally cause an error for the 3rd item to trigger error hook
      if item == 3
        # This will be caught and retried
        puts "Processor: Simulating an error for item #{item}"
        raise "Simulated error processing item #{item}"
      end

      # Process successfully
      processed = item * 10
      puts "Processor: Transformed item #{item} to #{processed}"
      emit(processed)
    end

    consumer :consumer do |item|
      puts "Consumer stage: Consuming item #{item}"
      # Simulate storing or recording the result
      puts "Consumer: Result saved - #{item}"
    end
  end
end

# Run the task if executed directly
HooksExample.new.run if __FILE__ == $PROGRAM_NAME
