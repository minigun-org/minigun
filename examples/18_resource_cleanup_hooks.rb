# frozen_string_literal: true

require_relative '../lib/minigun'

# Example: Resource Management with Stage Hooks
# Demonstrates setup/cleanup for external resources
class ResourceCleanupExample
  include Minigun::DSL

  max_threads 3
  max_processes 2

  attr_accessor :results, :resource_events, :file_handle, :api_client

  def initialize
    @results = []
    @resource_events = []
    @file_handle = nil
    @api_client = nil
  end

  pipeline do
    # Open file before producer starts
    before :read_file do
      @file_handle = open_file_handle
      @resource_events << "Opened file handle"
    end

    # Close file after producer finishes
    after :read_file do
      close_file_handle
      @resource_events << "Closed file handle"
    end

    producer :read_file do
      # Simulate reading from file
      @resource_events << "Reading from file..."
      10.times { |i| emit("record_#{i}") }
    end

    # Initialize API client before processing
    before :enrich_data do
      @api_client = initialize_api_client
      @resource_events << "Initialized API client"
    end

    # Cleanup API client after processing
    after :enrich_data do
      shutdown_api_client
      @resource_events << "Shutdown API client"
    end

    processor :enrich_data do |record|
      # Simulate API call to enrich data
      enriched = call_external_api(record)
      emit(enriched)
    end

    # Accumulator batches records
    accumulator :batch, max_size: 5

    process_per_batch(max: 2) do
      # Close connections before forking
      before_fork :save_to_db do
        @resource_events << "Closing connections before fork"
      end

      # Reopen connections after forking
      after_fork :save_to_db do
        @resource_events << "Reopening connections in child process"
      end

      consumer :save_to_db do |batch|
        batch.each { |record| @results << record }
      end
    end
  end

  private

  def open_file_handle
    @resource_events << "Opening file..."
    "FILE_HANDLE_#{Process.pid}"
  end

  def close_file_handle
    @resource_events << "Closing file..."
    @file_handle = nil
  end

  def initialize_api_client
    @resource_events << "Connecting to API..."
    "API_CLIENT_#{Process.pid}"
  end

  def shutdown_api_client
    @resource_events << "Disconnecting from API..."
    @api_client = nil
  end

  def call_external_api(record)
    "#{record}_enriched"
  end
end

if __FILE__ == $PROGRAM_NAME
  puts "=== Resource Cleanup Example ===\n\n"

  example = ResourceCleanupExample.new
  example.run

  puts "\n=== Results ==="
  puts "Processed: #{example.results.size} records"

  puts "\n=== Resource Events ==="
  example.resource_events.each_with_index do |event, i|
    puts "  #{i + 1}. #{event}"
  end

  puts "\n✓ Resource cleanup example complete!"
end

