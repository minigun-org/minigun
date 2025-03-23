# frozen_string_literal: true

require 'minigun'

class ConfiguredExample
  include Minigun::DSL

  # Global configuration
  max_threads 10        # Maximum threads per process
  max_processes 4       # Maximum forked processes
  max_retries 3         # Maximum retry attempts for errors
  batch_size 100        # Default batch size
  consumer_type :cow    # Default consumer fork implementation (:cow or :ipc)

  # Advanced IPC options
  pipe_timeout 30       # Timeout for IPC pipe operations (seconds)
  use_compression true  # Enable compression for large IPC transfers
  gc_probability 0.1    # Probability of GC during batch processing (0.0-1.0)

  # Stage-specific configuration
  pipeline do
    producer :source do
      10.times { |i| emit(i) }
    end

    processor :transform, threads: 5 do |item|
      # Process with 5 threads
      emit(item * 2)
    end

    accumulator :batch, max_queue: 1000, max_all: 2000 do |item|
      # Batch with custom limits
      @items ||= []
      @items << item

      if @items.size >= 3 # Using 3 instead of a larger number for the example
        batch = @items.dup
        @items.clear
        emit(batch)
      end
    end

    consumer :sink, fork: :ipc, processes: 2 do |batch|
      # Consume with 2 IPC processes
      puts "Processing batch in IPC consumer with 2 processes: #{batch.inspect}"
    end
  end

  before_run do
    puts 'Starting the configured task...'
  end

  after_run do
    puts 'Configured task completed!'
  end
end

# Run the task
ConfiguredTask.new.run if __FILE__ == $PROGRAM_NAME
