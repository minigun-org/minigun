# frozen_string_literal: true

require_relative '../lib/minigun'
require 'tempfile'

# Example: Statistics Gathering with Hooks
# Demonstrates tracking metrics at each stage
class StatisticsGatheringExample
  include Minigun::DSL

  max_threads 5
  max_processes 2

  attr_accessor :stats, :results

  def initialize
    @stats = {
      pipeline_start: nil,
      pipeline_end: nil,
      producer_start: nil,
      producer_end: nil,
      producer_count: 0,
      validator_start: nil,
      validator_end: nil,
      validator_passed: 0,
      validator_failed: 0,
      transformer_count: 0,
      consumer_start: nil,
      consumer_end: nil,
      consumer_count: 0,
      forks_created: 0,
      child_processes: []
    }
    @results = []
    @temp_pids_file = Tempfile.new(['minigun_pids', '.txt'])
    @temp_pids_file.close
    @temp_results_file = Tempfile.new(['minigun_results', '.txt'])
    @temp_results_file.close
  end

  def cleanup
    File.unlink(@temp_pids_file.path) if @temp_pids_file && File.exist?(@temp_pids_file.path)
    File.unlink(@temp_results_file.path) if @temp_results_file && File.exist?(@temp_results_file.path)
  end

  pipeline do
    # Track overall pipeline timing
    before_run do
      @stats[:pipeline_start] = Time.now
    end

    after_run do
      @stats[:pipeline_end] = Time.now
      @stats[:total_duration] = @stats[:pipeline_end] - @stats[:pipeline_start]
    end

    # Track producer statistics
    before :generate_data do
      @stats[:producer_start] = Time.now
    end

    after :generate_data do
      @stats[:producer_end] = Time.now
      @stats[:producer_duration] = @stats[:producer_end] - @stats[:producer_start]
    end

    producer :generate_data do
      100.times do |i|
        emit({ id: i, value: rand(100) })
        @stats[:producer_count] += 1
      end
    end

    # Track validation statistics
    before :validate do
      @stats[:validator_start] = Time.now
    end

    after :validate do
      @stats[:validator_end] = Time.now
      @stats[:validator_duration] = @stats[:validator_end] - @stats[:validator_start]
    end

    processor :validate do |item|
      if item[:value] > 50
        @stats[:validator_passed] += 1
        emit(item)
      else
        @stats[:validator_failed] += 1
        # Don't emit - filter out
      end
    end

    processor :transform do |item|
      @stats[:transformer_count] += 1
      emit(item.merge(transformed: true, doubled: item[:value] * 2))
    end

    # Accumulator batches items
    accumulator :batch, max_size: 25

    # Track consumer statistics and forks
    before :save_results do
      @stats[:consumer_start] = Time.now
    end

    after :save_results do
      @stats[:consumer_end] = Time.now
      @stats[:consumer_duration] = @stats[:consumer_end] - @stats[:consumer_start]
    end

    process_per_batch(max: 2) do
      before_fork :save_results do
        @stats[:forks_created] += 1
      end

      after_fork :save_results do
        # Write PID to temp file (fork-safe)
        File.open(@temp_pids_file.path, 'a') do |f|
          f.flock(File::LOCK_EX)
          f.puts(Process.pid)
          f.flock(File::LOCK_UN)
        end
      end

      consumer :save_results do |batch|
        # Write results to temp file (fork-safe)
        File.open(@temp_results_file.path, 'a') do |f|
          f.flock(File::LOCK_EX)
          batch.each { |item| f.puts(item.to_json) }
          f.flock(File::LOCK_UN)
        end
      end
    end

    after_run do
      # Read fork results from temp files
      if File.exist?(@temp_pids_file.path)
        @stats[:child_processes] = File.readlines(@temp_pids_file.path).map { |line| line.strip.to_i }.uniq
      end
      if File.exist?(@temp_results_file.path)
        @results = File.readlines(@temp_results_file.path).map { |line| JSON.parse(line.strip) }
        @stats[:consumer_count] = @results.size
      end
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  puts "=== Statistics Gathering Example ===\n\n"

  example = StatisticsGatheringExample.new
  begin
    example.run

  puts "\n=== Pipeline Statistics ==="
  puts "Total Duration:      #{example.stats[:total_duration]&.round(3)}s"
  puts ""

  puts "Producer:"
  puts "  Items Generated:   #{example.stats[:producer_count]}"
  puts "  Duration:          #{example.stats[:producer_duration]&.round(3)}s"
  puts "  Rate:              #{(example.stats[:producer_count] / example.stats[:producer_duration]).round(0)} items/sec" if example.stats[:producer_duration]
  puts ""

  puts "Validator:"
  puts "  Items Passed:      #{example.stats[:validator_passed]}"
  puts "  Items Failed:      #{example.stats[:validator_failed]}"
  puts "  Pass Rate:         #{(100.0 * example.stats[:validator_passed] / example.stats[:producer_count]).round(1)}%"
  puts "  Duration:          #{example.stats[:validator_duration]&.round(3)}s"
  puts ""

  puts "Transformer:"
  puts "  Items Transformed: #{example.stats[:transformer_count]}"
  puts ""

  puts "Consumer:"
  puts "  Items Consumed:    #{example.stats[:consumer_count]}"
  puts "  Forks Created:     #{example.stats[:forks_created]}"
  puts "  Child PIDs:        #{example.stats[:child_processes].uniq.join(', ')}"
  puts "  Duration:          #{example.stats[:consumer_duration]&.round(3)}s"
  puts ""

  puts "Final Results:       #{example.results.size} items saved"
  puts ""
  puts "✓ Statistics gathering example complete!"
  ensure
    example.cleanup
  end
end

