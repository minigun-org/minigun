# frozen_string_literal: true

require_relative '../lib/minigun'

# Example demonstrating emit_to_stage with cross-context routing
# This shows that IPC transport is automatically handled when routing
# between different execution contexts (threads, processes, etc.)

class CrossContextRoutingExample
  include Minigun::DSL

  attr_reader :stats

  def initialize
    @stats = {
      routed_to_fast: 0,
      routed_to_slow: 0,
      routed_to_heavy: 0
    }
    @mutex = Mutex.new
  end

  pipeline do
    producer :generate_tasks do
      puts "\n🎯 CROSS-CONTEXT ROUTING WITH emit_to_stage\n"
      puts "="*60

      # Generate different types of tasks
      tasks = [
        { id: 1, type: 'fast', workload: 'light' },
        { id: 2, type: 'slow', workload: 'medium' },
        { id: 3, type: 'heavy', workload: 'intensive' },
        { id: 4, type: 'fast', workload: 'light' },
        { id: 5, type: 'slow', workload: 'medium' },
        { id: 6, type: 'heavy', workload: 'intensive' },
        { id: 7, type: 'fast', workload: 'light' },
        { id: 8, type: 'slow', workload: 'medium' }
      ]

      tasks.each do |task|
        puts "📦 Generated #{task[:type]} task #{task[:id]}"
        emit(task)
      end
    end

    # Router stage - decides which consumer to route to based on task type
    # This stage runs inline (default)
    stage :router do |task|
      target_stage = case task[:type]
                     when 'fast'
                       :fast_processor
                     when 'slow'
                       :slow_processor
                     when 'heavy'
                       :heavy_processor
                     else
                       :fast_processor
                     end

      puts "  🔀 Routing task #{task[:id]} (#{task[:type]}) → #{target_stage}"
      
      # Use emit_to_stage to route to specific consumer
      # Each consumer runs in a different execution context
      emit_to_stage(target_stage, task)
      
      # Track routing
      @mutex.synchronize do
        case target_stage
        when :fast_processor
          @stats[:routed_to_fast] += 1
        when :slow_processor
          @stats[:routed_to_slow] += 1
        when :heavy_processor
          @stats[:routed_to_heavy] += 1
        end
      end
    end

    # Fast processor - runs in a thread pool (shared memory)
    threads(3) do
      consumer :fast_processor do |task|
        sleep 0.01  # Simulate fast work
        puts "    ⚡ [Thread #{Thread.current.object_id}] Fast processed task #{task[:id]}"
      end
    end

    # Slow processor - runs in a separate thread pool (shared memory)
    threads(2) do
      consumer :slow_processor do |task|
        sleep 0.05  # Simulate slower work
        puts "    🐢 [Thread #{Thread.current.object_id}] Slow processed task #{task[:id]}"
      end
    end

    # Heavy processor - runs in forked processes (IPC required!)
    process_per_batch(max: 2) do
      consumer :heavy_processor do |task|
        sleep 0.1  # Simulate heavy work
        puts "    💪 [Process #{Process.pid}] Heavy processed task #{task[:id]}"
      end
    end

    after_run do
      puts "\n" + "="*60
      puts "CROSS-CONTEXT ROUTING STATISTICS"
      puts "="*60
      puts "Tasks routed to fast_processor (thread pool): #{@stats[:routed_to_fast]}"
      puts "Tasks routed to slow_processor (thread pool): #{@stats[:routed_to_slow]}"
      puts "Tasks routed to heavy_processor (processes):  #{@stats[:routed_to_heavy]}"
      puts "\n✅ IPC transport was automatically handled for cross-context routing!"
    end
  end
end

# Run the example if executed directly
if __FILE__ == $0
  example = CrossContextRoutingExample.new
  example.run
end

