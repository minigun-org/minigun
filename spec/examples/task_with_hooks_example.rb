# frozen_string_literal: true

require 'minigun'

class TaskWithHooksExample
  include Minigun::DSL

  # Configure the task
  max_threads 5
  max_processes 2

  # Define lifecycle hooks
  before_run do
    puts 'HOOK: Before run - Initializing task resources'
    # Called before the pipeline starts
    @start_time = Time.now
  end

  after_run do
    # Called after the pipeline completes
    duration = Time.now - @start_time
    puts "HOOK: After run - Task completed in #{duration.round(2)} seconds"
  end

  before_fork do
    # Called in the parent process before forking
    puts 'HOOK: Before fork - Parent process preparing to fork'
  end

  after_fork do
    # Called in the child process after forking
    puts "HOOK: After fork - Child process #{Process.pid} initialized"
  end

  # Define a sample pipeline
  pipeline do
    producer :generate do
      5.times { |i| emit(i) }
    end

    processor :process do |item|
      puts "Processing item: #{item}"
      emit(item * 3)
    end

    cow_fork :handle_result do |item|
      # This will trigger the fork hooks
      puts "Handling result in forked process: #{item}"
    end
  end
end

# Run the task
TaskWithHooks.new.run if __FILE__ == $PROGRAM_NAME
