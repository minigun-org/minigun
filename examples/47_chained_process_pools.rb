# frozen_string_literal: true

require_relative '../lib/minigun'

# Example: Chained Process Pools IPC
# Demonstrates multiple process pools in series
# Producer -> Pool A (IPC) -> Pool B (IPC) -> Pool C (IPC) -> Consumer
class ChainedProcessPools
  include Minigun::DSL

  attr_accessor :results, :stage_counts

  def initialize
    @results = []
    @stage_counts = Hash.new(0)
  end

  pipeline do
    producer :generate do
      50.times { |i| emit(i) }
    end

    # First process pool: Parse/validate (3 workers)
    processes(3) do
      processor :parse do |num|
        @stage_counts[:parse] += 1
        puts "Parse pool (PID #{Process.pid}): #{num}" if num % 10 == 0
        
        # Data flows to next pool via IPC
        emit({ id: num, parsed: true })
      end
    end

    # Second process pool: Transform (4 workers)
    processes(4) do
      processor :transform do |data|
        @stage_counts[:transform] += 1
        puts "Transform pool (PID #{Process.pid}): #{data[:id]}" if data[:id] % 10 == 0
        
        # More IPC to next pool
        emit(data.merge(value: data[:id] * 2, transformed: true))
      end
    end

    # Third process pool: Enrich (2 workers)
    processes(2) do
      processor :enrich do |data|
        @stage_counts[:enrich] += 1
        puts "Enrich pool (PID #{Process.pid}): #{data[:id]}" if data[:id] % 10 == 0
        
        # Final IPC to consumer
        emit(data.merge(enriched: true, timestamp: Time.now.to_i))
      end
    end

    # Consumer in main process
    consumer :save do |data|
      @stage_counts[:save] += 1
      @results << data
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  puts "=== Chained Process Pools IPC Example ===\n\n"
  puts "This demonstrates:"
  puts "  - Three process pools in series"
  puts "  - Data flows through 3 IPC boundaries"
  puts "  - Each pool has different number of workers"
  puts "  - IPC: Producer -> Parse(3) -> Transform(4) -> Enrich(2) -> Consumer\n\n"

  pipeline = ChainedProcessPools.new
  pipeline.run

  puts "\n=== Results ==="
  puts "Total processed: #{pipeline.results.size} items"
  puts "Sample result: #{pipeline.results.first.inspect}"
  
  puts "\n=== Stage Counts ==="
  pipeline.stage_counts.each do |stage, count|
    puts "  #{stage}: #{count} items"
  end
  
  # Verify all stages processed all items
  expected = 50
  pipeline.stage_counts.each do |stage, count|
    if count != expected
      puts "\n⚠️  Warning: #{stage} processed #{count} items, expected #{expected}"
    end
  end

  puts "\n✓ Chained process pools IPC complete!"
  puts "✓ Data successfully flowed through 3 IPC boundaries!"
end

