# frozen_string_literal: true

require_relative '../lib/minigun'
require 'tempfile'

# Example: Inline Hook Procs (Option 3)
# Demonstrates concise hook syntax for simple operations
class InlineHookExample
  include Minigun::DSL

  max_threads 3
  max_processes 2

  attr_accessor :results, :events, :timer

  def initialize
    @results = []
    @events = []
    @timer = {}
    @temp_file = Tempfile.new(['minigun_inline_results', '.txt'])
    @temp_file.close
    @events_file = Tempfile.new(['minigun_inline_events', '.txt'])
    @events_file.close
  end

  def cleanup
    File.unlink(@temp_file.path) if @temp_file && File.exist?(@temp_file.path)
    File.unlink(@events_file.path) if @events_file && File.exist?(@events_file.path)
  end

  pipeline do
    # Traditional pipeline-level hooks
    before_run do
      @events << :pipeline_start
    end

    after_run do
      @events << :pipeline_end
    end

    # Inline hooks for simple operations
    producer :fetch_data,
             before: -> { @timer[:fetch_start] = Time.now },
             after: -> { @timer[:fetch_end] = Time.now } do
      @events << :fetching
      10.times { |i| emit(i) }
    end

    # Inline hooks with multiple operations
    processor :validate,
              before: -> {
                @events << :validate_start
                @validation_count = 0
              },
              after: -> {
                @events << :validate_end
                puts "Validated #{@validation_count} items"
              } do |num|
      @validation_count += 1
      if num > 0
        emit(num)
      end
    end

    # Inline hooks for processors
    processor :transform,
              before: -> { @events << :transform_start },
              after: -> { @events << :transform_end } do |num|
      emit(num * 2)
    end

    # Accumulator batches items
    accumulator :batch, max_size: 5

    # Inline fork hooks for consumers
    process_per_batch(max: 2) do
      consumer :save_data,
               before: -> { @timer[:save_start] = Time.now },
               after: -> { @timer[:save_end] = Time.now },
               before_fork: -> {
                 @events << :before_fork
                 puts "About to fork..."
               },
               after_fork: -> {
                 # Write event to file (child process can't mutate parent's @events)
                 File.open(@events_file.path, 'a') do |f|
                   f.flock(File::LOCK_EX)
                   f.puts('after_fork')
                   f.flock(File::LOCK_UN)
                 end
                 puts "Forked! Child PID: #{Process.pid}"
               } do |batch|
        # Write to temp file (fork-safe)
        File.open(@temp_file.path, 'a') do |f|
          f.flock(File::LOCK_EX)
          batch.each { |num| f.puts(num) }
          f.flock(File::LOCK_UN)
        end
      end
    end

    after_run do
      # Read fork results from temp file
      if File.exist?(@temp_file.path)
        @results = File.readlines(@temp_file.path).map { |line| line.strip.to_i }
      end

      # Read fork events from events file
      if File.exist?(@events_file.path)
        fork_events = File.readlines(@events_file.path).map { |line| line.strip.to_sym }
        @events.concat(fork_events)
      end
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  puts "=== Inline Hook Procs Example ===\n\n"

  example = InlineHookExample.new
  begin
    example.run

    puts "\n=== Results ==="
    puts "Processed: #{example.results.size} items"
    puts "Results: #{example.results.sort.inspect}"

    puts "\n=== Events ==="
    example.events.each { |event| puts "  - #{event}" }

    puts "\n=== Timing ==="
    if example.timer[:fetch_start] && example.timer[:fetch_end]
      puts "Fetch duration: #{(example.timer[:fetch_end] - example.timer[:fetch_start]).round(3)}s"
    end
    if example.timer[:save_start] && example.timer[:save_end]
      puts "Save duration:  #{(example.timer[:save_end] - example.timer[:save_start]).round(3)}s"
    end

    puts "\n✓ Inline hook procs example complete!"
  ensure
    example.cleanup
  end
end

