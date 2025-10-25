# frozen_string_literal: true

require_relative '../lib/minigun'

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
  end

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
  end

  # Clean up after everything completes
  after_run do
    final_disconnect
  end

  producer :fetch_user_ids do
    @connection_events << "Producer using DB connection"
    # Simulate fetching IDs from database
    (1..10).each { |id| emit(id) }
  end

  # Accumulator batches items
  accumulator :batch, max_size: 5

  # Use spawn_fork to process batches
  spawn_fork :process_users do |batch|
    batch.each do |user_id|
      @connection_events << "Processing user #{user_id} in PID #{Process.pid}"
      # Simulate database write
      result = save_to_database(user_id)
      @results << result
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
  example.run

  puts "\n=== Results ==="
  puts "Processed: #{example.results.size} users"
  puts "\n=== Connection Events ==="
  example.connection_events.each { |event| puts "  #{event}" }
  puts "\n✓ Database connection example complete!"
end

