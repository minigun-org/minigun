# frozen_string_literal: true

require 'minigun'

class ConfiguredExample
  include Minigun::DSL

  # Global configuration
  max_threads 5         # Maximum threads per process (updated to match test)
  max_processes 3       # Maximum forked processes (updated to match test)
  max_retries 3         # Maximum retry attempts for errors
  batch_size 20         # Default batch size (updated to match test)
  consumer_type :cow    # Default consumer fork implementation (:cow or :ipc)

  # Custom configuration not directly mapped to Minigun options
  _minigun_task.config[:retry_delay] = 1.5  # Retry delay in seconds

  # Pipeline definition
  pipeline do
    producer :source do
      puts "Starting configured task"
      puts "Environment: #{@environment}"
      10.times do |i| 
        puts "Producing item #{i}"
        emit(i)
      end
    end

    processor :processor do |item|
      puts "Processing data: #{item}"
      emit(item * 2)
    end

    consumer :sink do |item|
      puts "Consuming item: #{item}"
    end
  end

  before_run do
    puts 'Starting the configured task...'
  end

  after_run do
    puts 'Task completed!'
  end
  
  # Support for constructor parameters
  attr_reader :max_items, :environment, :test_mode
  
  def initialize(options = {})
    @max_items = options[:max_items] || 10
    @batch_size = options[:batch_size] || 20
    @environment = options[:environment] || 'production'
    @test_mode = @environment == 'test'
  end
  
  # Allow accessing batch_size from tests
  def batch_size
    @batch_size
  end
end

# Run the task if executed directly
ConfiguredExample.new.run if __FILE__ == $PROGRAM_NAME
