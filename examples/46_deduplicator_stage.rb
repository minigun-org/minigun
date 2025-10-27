# frozen_string_literal: true

require_relative '../lib/minigun'
require 'set'

# Custom stage that filters duplicate items based on accumulated state
class DeduplicatorStage < Minigun::Stage
  def initialize(name:, options: {})
    super
    @seen = Set.new
    @mutex = Mutex.new
    @key_method = options[:key_method] || :itself
  end

  def run_mode
    :streaming
  end

  def run_worker_loop(stage_ctx)
    require_relative '../lib/minigun/queue_wrappers'

    # Create wrapped queues
    wrapped_input = Minigun::InputQueue.new(
      stage_ctx.input_queue,
      stage_ctx.stage_name,
      stage_ctx.sources_expected
    )
    wrapped_output = Minigun::OutputQueue.new(
      stage_ctx.stage_name,
      stage_ctx.dag.downstream(stage_ctx.stage_name).map { |ds|
        stage_ctx.stage_input_queues[ds]
      },
      stage_ctx.stage_input_queues,
      stage_ctx.runtime_edges
    )

    # Process items one-by-one
    loop do
      item = wrapped_input.pop

      # Handle end of stream
      break if item.is_a?(Minigun::AllUpstreamsDone)

      # Check for duplicates
      key = extract_key(item)
      is_new = @mutex.synchronize do
        if @seen.include?(key)
          false
        else
          @seen.add(key)
          true
        end
      end

      # Forward only new items
      wrapped_output << item if is_new
    end

    send_end_signals(stage_ctx)
  end

  private

  def extract_key(item)
    if @key_method.respond_to?(:call)
      @key_method.call(item)
    elsif item.respond_to?(@key_method)
      item.send(@key_method)
    else
      item
    end
  end
end

# Example with simple values
class SimpleDeduplicatorExample
  include Minigun::DSL

  pipeline do
    producer :generate do |output|
      # Emit numbers with duplicates
      [1, 2, 3, 2, 4, 1, 5, 3, 6, 4].each do |num|
        output << num
      end
    end

    # Use custom deduplicator stage
    custom_stage DeduplicatorStage, :dedupe

    consumer :collect do |item, output|
      puts "Unique item: #{item}"
    end
  end
end

# Example with hash objects
class HashDeduplicatorExample
  include Minigun::DSL

  pipeline do
    producer :generate do |output|
      # Emit user objects with duplicate IDs
      users = [
        { id: 1, name: "Alice" },
        { id: 2, name: "Bob" },
        { id: 1, name: "Alice (duplicate)" },
        { id: 3, name: "Charlie" },
        { id: 2, name: "Bob (duplicate)" },
        { id: 4, name: "David" }
      ]

      users.each { |user| output << user }
    end

    # Use custom deduplicator stage with key extraction
    custom_stage DeduplicatorStage, :dedupe, key_method: ->(item) { item[:id] }

    consumer :collect do |user, output|
      puts "Unique user: #{user.inspect}"
    end
  end
end

# Example with multi-threaded processing
class ThreadedDeduplicatorExample
  include Minigun::DSL

  pipeline do
    producer :generate do |output|
      # Emit lots of data with duplicates
      100.times do |i|
        output << (i % 20)  # Creates duplicates
      end
    end

    # Use custom deduplicator stage
    custom_stage DeduplicatorStage, :dedupe

    # Process with threads to test thread safety
    processor :transform, threads: 3 do |item, output|
      output << "processed_#{item}"
    end

    consumer :collect do |item, output|
      puts "Final item: #{item}"
    end
  end
end

if __FILE__ == $0
  puts "\n=== Simple Deduplicator Example ==="
  puts "Input: [1, 2, 3, 2, 4, 1, 5, 3, 6, 4]"
  puts "Expected output: [1, 2, 3, 4, 5, 6]\n\n"

  SimpleDeduplicatorExample.new.run

  puts "\n=== Hash Deduplicator Example ==="
  puts "Deduplicates by :id key\n\n"

  HashDeduplicatorExample.new.run

  puts "\n=== Threaded Deduplicator Example ==="
  puts "Tests thread safety with concurrent processing\n\n"

  ThreadedDeduplicatorExample.new.run

  puts "\n=== Examples Complete ==="
end

