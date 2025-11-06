# frozen_string_literal: true

require_relative '../lib/minigun'
require 'tempfile'

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
    @temp_file = Tempfile.new(['minigun_resource_results', '.txt'])
    @temp_file.close
    @temp_events_file = Tempfile.new(['minigun_resource_events', '.txt'])
    @temp_events_file.close
  end

  def cleanup
    File.unlink(@temp_file.path) if @temp_file && File.exist?(@temp_file.path)
    File.unlink(@temp_events_file.path) if @temp_events_file && File.exist?(@temp_events_file.path)
  end

  pipeline do
    # Open file before producer starts
    before :read_file do
      @file_handle = open_file_handle
      @resource_events << 'Opened file handle'
    end

    # Close file after producer finishes
    after :read_file do
      close_file_handle
      @resource_events << 'Closed file handle'
    end

    producer :read_file do |output|
      # Simulate reading from file
      @resource_events << 'Reading from file...'
      10.times { |i| output << "record_#{i}" }
    end

    # Initialize API client before processing
    before :enrich_data do
      @api_client = initialize_api_client
      @resource_events << 'Initialized API client'
    end

    # Cleanup API client after processing
    after :enrich_data do
      shutdown_api_client
      @resource_events << 'Shutdown API client'
    end

    processor :enrich_data do |record, output|
      # Simulate API call to enrich data
      enriched = call_external_api(record)
      output << enriched
    end

    # Accumulator batches records
    accumulator :batch, max_size: 5

    cow_fork(2) do
      # Close connections before forking
      before_fork :save_to_db do
        @resource_events << 'Closing connections before fork'
      end

      # Reopen connections after forking
      after_fork :save_to_db do
        # Log to temp file (child process can't mutate parent's array)
        File.open(@temp_events_file.path, 'a') do |f|
          f.flock(File::LOCK_EX)
          f.puts('Reopening connections in child process')
          f.flock(File::LOCK_UN)
        end
      end

      consumer :save_to_db do |batch|
        # Write to temp file (fork-safe)
        File.open(@temp_file.path, 'a') do |f|
          f.flock(File::LOCK_EX)
          batch.each { |record| f.puts(record) }
          f.flock(File::LOCK_UN)
        end
      end
    end

    after_run do
      # Read fork results from temp files
      @results = File.readlines(@temp_file.path).map(&:strip) if File.exist?(@temp_file.path)
      if File.exist?(@temp_events_file.path)
        fork_events = File.readlines(@temp_events_file.path).map(&:strip)
        @resource_events.concat(fork_events)
      end
    end
  end

  private

  def open_file_handle
    @resource_events << 'Opening file...'
    "FILE_HANDLE_#{Process.pid}"
  end

  def close_file_handle
    @resource_events << 'Closing file...'
    @file_handle = nil
  end

  def initialize_api_client
    @resource_events << 'Connecting to API...'
    "API_CLIENT_#{Process.pid}"
  end

  def shutdown_api_client
    @resource_events << 'Disconnecting from API...'
    @api_client = nil
  end

  def call_external_api(record)
    "#{record}_enriched"
  end
end

if __FILE__ == $PROGRAM_NAME
  puts "=== Resource Cleanup Example ===\n\n"

  example = ResourceCleanupExample.new
  begin
    example.run

    puts "\n=== Results ==="
    puts "Processed: #{example.results.size} records"

    puts "\n=== Resource Events ==="
    example.resource_events.each_with_index do |event, i|
      puts "  #{i + 1}. #{event}"
    end

    puts "\n✓ Resource cleanup example complete!"
  ensure
    example.cleanup
  end
end
