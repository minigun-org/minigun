# frozen_string_literal: true

require 'minigun'

class IpcForkExample
  include Minigun::DSL

  # Configure IPC settings
  pipe_timeout 60 # Timeout for pipe operations (seconds)
  max_chunk_size 2_000_000 # Max size for chunked data (bytes)
  use_compression true    # Enable compression
  gc_probability 0.2      # GC probability

  pipeline do
    producer :generate_data do
      # Generate sample data that will be modified by child processes
      data = (1..5).map do |i|
        {
          id: i,
          name: "Record #{i}",
          mutable_data: { count: 0, items: [] }
        }
      end

      data.each_slice(2) do |batch|
        puts "Generating batch of #{batch.size} items for IPC processing"
        emit(batch)
      end
    end

    ipc_fork :process_batch do |batch|
      # Process items in a child process with explicit IPC communication
      puts "Processing batch in IPC fork process #{Process.pid}"

      # Modify the data (this would break copy-on-write sharing)
      modified_batch = batch.map do |item|
        # Heavy modification of the data
        item[:mutable_data][:count] = rand(1000)
        item[:mutable_data][:items] = Array.new(100) { |j| "Item #{j}" }
        item[:processed_by] = "Process #{Process.pid}"
        item[:timestamp] = Time.now.to_i
        item
      end

      puts "Batch processed with IPC. First item count: #{modified_batch.first[:mutable_data][:count]}"
      puts 'IPC will serialize these changes back to the parent process'
    end

    consumer :verify_results, from: :process_batch do |_result|
      puts 'Results received back in parent process after IPC processing'
    end
  end

  before_fork do
    puts 'Preparing to fork with IPC...'
  end

  after_fork do
    puts "IPC fork process #{Process.pid} initialized"
  end
end

# Run the task
IpcForkExample.new.run if __FILE__ == $PROGRAM_NAME
