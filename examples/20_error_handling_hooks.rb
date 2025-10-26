# frozen_string_literal: true

require_relative '../lib/minigun'
require 'tempfile'

# Example: Error Handling and Recovery with Hooks
# Demonstrates error detection and handling patterns
class ErrorHandlingExample
  include Minigun::DSL

  max_threads 5
  max_processes 2

  attr_accessor :results, :errors, :retry_counts

  def initialize
    @results = []
    @errors = []
    @retry_counts = Hash.new(0)
    @failed_items = []
    @circuit_breaker_open = false
    @temp_file = Tempfile.new(['minigun_error_results', '.json'])
    @temp_file.close
  end

  def cleanup
    File.unlink(@temp_file.path) if @temp_file && File.exist?(@temp_file.path)
  end

  pipeline do
    # Initialize error tracking
    before_run do
      @errors.clear
      @start_time = Time.now
    end

    # Report errors after completion
    after_run do
      if @errors.any?
        puts "\n⚠️  #{@errors.size} errors occurred during processing"
      else
        puts "\n✓ Pipeline completed successfully with no errors"
      end
    end

    producer :generate_data do
      # Generate mix of good and potentially problematic data
      20.times do |i|
        emit({ id: i, value: i })
      end
    end

    # Validate data and catch errors
    before :validate do
      @validation_start = Time.now
    end

    after :validate do
      validation_duration = Time.now - @validation_start
      puts "Validation completed in #{validation_duration.round(3)}s"
    end

    processor :validate do |item|
      begin
        # Simulate validation that might fail
        if item[:id] == 13
          raise StandardError, "Unlucky number 13!"
        end

        if item[:value] < 0
          raise ArgumentError, "Value cannot be negative"
        end

        emit(item)
      rescue => e
        @errors << { stage: :validate, item: item, error: e.message }
        # Don't re-emit - filter out bad data
      end
    end

    # Process with retry logic
    processor :transform do |item|
      max_retries = 3

      begin
        @retry_counts[item[:id]] += 1

        # Simulate intermittent failures
        if item[:id] == 7 && @retry_counts[item[:id]] < 2
          raise "Temporary failure for item #{item[:id]}"
        end

        transformed = item.merge(
          doubled: item[:value] * 2,
          processed_at: Time.now
        )

        emit(transformed)
      rescue => e
        if @retry_counts[item[:id]] < max_retries
          # Retry by re-emitting
          emit(item)
        else
          @errors << { stage: :transform, item: item, error: e.message, retries: @retry_counts[item[:id]] }
          @failed_items << item
        end
      end
    end

    # Accumulator batches items
    accumulator :batch, max_size: 10

    # Consumer with error isolation
    before_fork :save_results do
      # Reset error tracking for child process
      @process_errors = []
    end

    process_per_batch(max: 2) do
      after_fork :save_results do
        # Report errors from this child process
        if @process_errors&.any?
          puts "Child process #{Process.pid} had #{@process_errors.size} errors"
        end
      end

      consumer :save_results do |batch|
        batch.each do |item|
          begin
            # Simulate save that might fail
            if item[:id] == 15
              raise "Database connection lost"
            end

            # Write to temp file (fork-safe)
            File.open(@temp_file.path, 'a') do |f|
              f.flock(File::LOCK_EX)
              f.puts(item.to_json)
              f.flock(File::LOCK_UN)
            end
          rescue => e
            (@process_errors ||= []) << { item: item, error: e.message }
            @errors << { stage: :save_results, item: item, error: e.message }
          end
        end
      end
    end

    after_run do
      # Read fork results from temp file
      if File.exist?(@temp_file.path)
        @results = File.readlines(@temp_file.path).map { |line| JSON.parse(line.strip) }
      end
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  puts "=== Error Handling Example ===\n\n"

  example = ErrorHandlingExample.new
  begin
    example.run

    puts "\n=== Results ==="
    puts "Successfully processed: #{example.results.size} items"
    puts "Total errors:          #{example.errors.size}"

    if example.errors.any?
      puts "\n=== Error Details ==="
      example.errors.group_by { |e| e[:stage] }.each do |stage, errors|
        puts "\n#{stage}:"
        errors.each do |err|
          puts "  - Item #{err[:item][:id]}: #{err[:error]}"
          puts "    (#{err[:retries]} retries)" if err[:retries]
        end
      end
    end

    if example.retry_counts.any?
      puts "\n=== Retry Statistics ==="
      example.retry_counts.each do |id, count|
        puts "  Item #{id}: #{count} attempts" if count > 1
      end
    end

    puts "\n✓ Error handling example complete!"
  ensure
    example.cleanup
  end
end

