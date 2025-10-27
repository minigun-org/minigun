# frozen_string_literal: true

require_relative '../lib/minigun'

# Custom stage that batches items with a timeout
class TimedBatchStage < Minigun::Stage
  attr_reader :batch_size, :timeout

  def initialize(name:, options: {})
    super
    @batch_size = options[:batch_size] || 100
    @timeout = options[:timeout] || 5.0
  end

  def run_mode
    :streaming  # Processes items from input queue
  end

  def run_worker_loop(stage_ctx)
    require_relative '../lib/minigun/queue_wrappers'

    # Get stage stats for tracking
    stage_stats = stage_ctx.stats.for_stage(stage_ctx.stage_name, is_terminal: stage_ctx.dag.terminal?(stage_ctx.stage_name))

    # Create wrapped output queue
    wrapped_output = Minigun::OutputQueue.new(
      stage_ctx.stage_name,
      stage_ctx.dag.downstream(stage_ctx.stage_name).map { |ds|
        stage_ctx.stage_input_queues[ds]
      },
      stage_ctx.stage_input_queues,
      stage_ctx.runtime_edges,
      stage_stats: stage_stats
    )

    batch = []
    last_flush = Time.now
    sources_done = Set.new

    loop do
      # Check for timeout
      if !batch.empty? && (Time.now - last_flush) >= @timeout
        wrapped_output << batch.dup
        batch.clear
        last_flush = Time.now
      end

      # Try to get item with timeout (use underlying queue directly)
      begin
        msg = stage_ctx.input_queue.pop(timeout: 0.1)

        # nil means timeout - continue to check timeout condition
        next if msg.nil?

        # Handle END signal
        if msg.is_a?(Minigun::Message) && msg.end_of_stream?
          stage_ctx.sources_expected << msg.source  # Discover dynamic sources
          sources_done << msg.source

          # All sources done?
          if sources_done == stage_ctx.sources_expected
            # Flush remaining items
            wrapped_output << batch unless batch.empty?
            break
          end
          next
        end

        # Add item to batch
        batch << msg

        # Flush if batch is full
        if batch.size >= @batch_size
          wrapped_output << batch.dup
          batch.clear
          last_flush = Time.now
        end
      rescue ThreadError
        # Queue empty - continue to check timeout condition
        next
      end
    end

    send_end_signals(stage_ctx)
  end
end

# Example task using TimedBatchStage
class TimedBatchExample
  include Minigun::DSL

  pipeline do
    producer :generate do |output|
      20.times do |i|
        output << i
        sleep 0.05  # Simulate slow production
      end
    end

    # Use custom stage class with small batch size and short timeout
    custom_stage TimedBatchStage, :batch, batch_size: 5, timeout: 0.3

    consumer :process do |batch, output|
      puts "Processing batch of #{batch.size} items: #{batch.inspect}"
    end
  end
end

if __FILE__ == $0
  puts "\n=== Timed Batch Stage Example ==="
  puts "Batches items with size limit (5) and timeout (0.3s)"
  puts "Watch how batches are flushed both when full and on timeout\n\n"

  TimedBatchExample.new.run

  puts "\n=== Example Complete ==="
end

