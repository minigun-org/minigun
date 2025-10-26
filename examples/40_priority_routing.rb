# frozen_string_literal: true

require_relative '../lib/minigun'

# Priority Routing Pattern
# Demonstrates routing items to different processing paths based on priority
class PriorityRoutingExample
  include Minigun::DSL

  attr_reader :stats

  def initialize
    @stats = Hash.new(0)
    @mutex = Mutex.new
  end

  pipeline do
    producer :generate_tasks do
      puts "\n" + "="*60
      puts "PRIORITY ROUTER: Generating Tasks"
      puts "="*60

      # Generate tasks with different priorities
      tasks = [
        { id: 1, type: 'email', priority: 'high', user: 'alice@example.com', vip: true },
        { id: 2, type: 'email', priority: 'low', user: 'bob@example.com', vip: false },
        { id: 3, type: 'notification', priority: 'critical', user: 'charlie@example.com', vip: true },
        { id: 4, type: 'email', priority: 'medium', user: 'diana@example.com', vip: false },
        { id: 5, type: 'sms', priority: 'critical', user: 'eve@example.com', vip: true },
        { id: 6, type: 'notification', priority: 'low', user: 'frank@example.com', vip: false },
        { id: 7, type: 'email', priority: 'high', user: 'grace@example.com', vip: true },
        { id: 8, type: 'sms', priority: 'medium', user: 'henry@example.com', vip: false },
        { id: 9, type: 'notification', priority: 'critical', user: 'iris@example.com', vip: true },
        { id: 10, type: 'email', priority: 'low', user: 'jack@example.com', vip: false }
      ]

      tasks.each do |task|
        badge = task[:vip] ? '⭐' : '  '
        puts "#{badge} Generated task #{task[:id]}: #{task[:type]} [#{task[:priority]}] for #{task[:user]}"
        emit(task)
      end
    end

    # Enrich tasks with priority score
    processor :calculate_priority do |task|
      # Calculate priority score
      priority_score = case task[:priority]
                       when 'critical' then 100
                       when 'high' then 75
                       when 'medium' then 50
                       when 'low' then 25
                       end

      # VIP users get +20 bonus
      priority_score += 20 if task[:vip]

      task[:priority_score] = priority_score
      task[:routing_path] = if priority_score >= 100
                              'critical_path'
                            elsif priority_score >= 75
                              'high_priority_path'
                            elsif priority_score >= 50
                              'normal_path'
                            else
                              'low_priority_path'
                            end

      puts "→ Task #{task[:id]} scored #{priority_score} → routing to #{task[:routing_path]}"
      emit(task)
    end

    # Split processing based on routing path
    processor :route_by_priority do |task|
      # In a real system with emit_to_queue, we'd route to different queues
      # For now, we'll mark it and handle in the consumer
      task[:routed_at] = Time.now
      emit(task)
    end

    # Process with appropriate resources based on priority
    processor :process_task do |task|
      path = task[:routing_path]

      # Simulate different processing speeds
      delay = case path
              when 'critical_path' then 0.01  # Fast processing
              when 'high_priority_path' then 0.02
              when 'normal_path' then 0.03
              when 'low_priority_path' then 0.05  # Slower processing
              end

      sleep(delay)

      # Track stats
      @mutex.synchronize do
        @stats[path] += 1
      end

      task[:processed_at] = Time.now
      task[:processing_time] = delay

      icon = case path
             when 'critical_path' then '🔥'
             when 'high_priority_path' then '⚡'
             when 'normal_path' then '📝'
             when 'low_priority_path' then '🐌'
             end

      puts "#{icon} Processed task #{task[:id]} via #{path} in #{delay}s"
      emit(task)
    end

    # Final delivery
    consumer :deliver do |task|
      puts "✓ Delivered #{task[:type]} to #{task[:user]} (priority: #{task[:priority]}, score: #{task[:priority_score]})"
    end

    after_run do
      puts "\n" + "="*60
      puts "PRIORITY ROUTING STATISTICS"
      puts "="*60

      total = @stats.values.sum
      @stats.sort_by { |_, count| -count }.each do |path, count|
        percentage = (count * 100.0 / total).round(1)
        puts "#{path.ljust(25)} #{count} tasks (#{percentage}%)"
      end

      puts "\nPriority routing complete!"
      puts "="*60
    end
  end
end

# Run if executed directly
if __FILE__ == $PROGRAM_NAME
  PriorityRoutingExample.new.run
end

