# frozen_string_literal: true

require_relative '../lib/minigun'
require 'tempfile'

# Example: Database Connection Management with Fork Hooks
# Demonstrates proper disconnect/reconnect pattern for forked processes
class DatabaseConnectionExample
  include Minigun::DSL

  max_threads 5
  max_processes 2

  attr_accessor :results, :connection_events

  def initialize
    @results = []
    @connection_events = []
    @db_connected = false
    @temp_file = Tempfile.new(['minigun_db_results', '.txt'])
    @temp_file.close
    @temp_events_file = Tempfile.new(['minigun_db_events', '.txt'])
    @temp_events_file.close
  end

  def cleanup
    File.unlink(@temp_file.path) if @temp_file && File.exist?(@temp_file.path)
    File.unlink(@temp_events_file.path) if @temp_events_file && File.exist?(@temp_events_file.path)
  end

  def log_event(event)
    @connection_events << event
    # Also write to temp file for fork-safe logging
    File.open(@temp_events_file.path, 'a') do |f|
      f.flock(File::LOCK_EX)
      f.puts(event)
      f.flock(File::LOCK_UN)
    end
  end

  pipeline do
    # Simulate database connection
    before_run do
      connect_to_database
    end

    # Disconnect before forking (parent process)
    before_fork do
      disconnect_from_database
    end

    # Reconnect after forking (child process)
    after_fork do
      reconnect_in_child_process
      # Log to temp file (child process can't mutate parent's array)
      File.open(@temp_events_file.path, 'a') do |f|
        f.flock(File::LOCK_EX)
        f.puts("Reconnected to database in child (PID #{Process.pid})")
        f.flock(File::LOCK_UN)
      end
    end

    # Clean up after everything completes
    after_run do
      final_disconnect
    end

    producer :fetch_user_ids do |output|
      @connection_events << "Producer using DB connection"
      # Simulate fetching IDs from database
      (1..10).each { |id| output << id }
    end

    # Accumulator batches items
    accumulator :batch, max_size: 5

    # Use process_per_batch to process batches
    process_per_batch(max: 2) do
      consumer :process_users do |batch|
        batch.each do |user_id|
          @connection_events << "Processing user #{user_id} in PID #{Process.pid}"
          # Simulate database write
          result = save_to_database(user_id)

          # Write to temp file (fork-safe)
          File.open(@temp_file.path, 'a') do |f|
            f.flock(File::LOCK_EX)
            f.puts(result)
            f.flock(File::LOCK_UN)
          end
        end
      end
    end

    after_run do
      # Read fork results from temp files
      if File.exist?(@temp_file.path)
        @results = File.readlines(@temp_file.path).map(&:strip)
      end
      if File.exist?(@temp_events_file.path)
        fork_events = File.readlines(@temp_events_file.path).map(&:strip)
        @connection_events.concat(fork_events)
      end
    end
  end

  private

  def connect_to_database
    @db_connected = true
    @connection_events << "Connected to database in parent (PID #{Process.pid})"
  end

  def disconnect_from_database
    @db_connected = false
    @connection_events << "Disconnected from database before fork (PID #{Process.pid})"
  end

  def reconnect_in_child_process
    @db_connected = true
    @connection_events << "Reconnected to database in child (PID #{Process.pid})"
  end

  def final_disconnect
    @db_connected = false
    @connection_events << "Final disconnect (PID #{Process.pid})"
  end

  def save_to_database(user_id)
    raise "Not connected to database!" unless @db_connected
    "User #{user_id} saved"
  end
end

if __FILE__ == $PROGRAM_NAME
  puts "=== Database Connection Management Example ===\n\n"

  example = DatabaseConnectionExample.new
  begin
    example.run

    puts "\n=== Results ==="
    puts "Processed: #{example.results.size} users"
    puts "\n=== Connection Events ==="
    example.connection_events.each { |event| puts "  #{event}" }
    puts "\n✓ Database connection example complete!"
  ensure
    example.cleanup
  end
end

