# frozen_string_literal: true

require_relative '../lib/minigun'

# Message Router Pattern
# Demonstrates routing different message types to specialized handlers
class MessageRouterExample
  include Minigun::DSL

  attr_reader :message_counts

  def initialize
    @message_counts = Hash.new(0)
    @mutex = Mutex.new
  end

  pipeline do
    producer :generate_messages do
      puts "\n" + "="*60
      puts "MESSAGE ROUTER: Generating Messages"
      puts "="*60

      # Message types with different characteristics
      message_types = [
        { type: 'log', icon: '📋', needs_aggregation: true },
        { type: 'alert', icon: '🚨', needs_aggregation: false },
        { type: 'metric', icon: '📊', needs_aggregation: true },
        { type: 'event', icon: '⚡', needs_aggregation: false },
        { type: 'trace', icon: '🔍', needs_aggregation: true }
      ]

      # Generate 25 random messages
      25.times do |i|
        msg_type = message_types.sample
        message = {
          id: i + 1,
          type: msg_type[:type],
          icon: msg_type[:icon],
          content: "#{msg_type[:type].upcase} message ##{i + 1}",
          timestamp: Time.now.to_i + i,
          severity: %w[debug info warn error critical].sample,
          source: ['app-server', 'database', 'cache', 'queue'].sample
        }

        puts "#{message[:icon]} Generated #{message[:type]} message #{message[:id]}: #{message[:severity]}"
        emit(message)
      end
    end

    # Route messages based on type
    processor :classify_message do |message|
      # Add routing metadata
      message[:handler] = case message[:type]
                          when 'log' then 'log_processor'
                          when 'alert' then 'alert_processor'
                          when 'metric' then 'metric_processor'
                          when 'event' then 'event_processor'
                          when 'trace' then 'trace_processor'
                          else 'default_processor'
                          end

      puts "→ Routing #{message[:type]} message #{message[:id]} to #{message[:handler]}"
      emit(message)
    end

    # Process logs
    processor :process_message do |message|
      handler = message[:handler]

      # Simulate different processing based on type
      case handler
      when 'log_processor'
        message[:log_level] = message[:severity]
        message[:indexed] = true
        puts "  📋 LOG: [#{message[:log_level]}] from #{message[:source]}"

      when 'alert_processor'
        message[:notification_sent] = true
        message[:channels] = message[:severity] == 'critical' ? ['email', 'sms', 'slack'] : ['email']
        puts "  🚨 ALERT: [#{message[:severity]}] → notify via #{message[:channels].join(', ')}"

      when 'metric_processor'
        message[:value] = rand(1..100)
        message[:unit] = ['ms', 'bytes', 'count', 'percent'].sample
        puts "  📊 METRIC: #{message[:value]} #{message[:unit]} from #{message[:source]}"

      when 'event_processor'
        message[:event_type] = ['user.login', 'user.logout', 'order.created', 'payment.processed'].sample
        puts "  ⚡ EVENT: #{message[:event_type]} at #{message[:source]}"

      when 'trace_processor'
        message[:span_id] = "span-#{rand(1000..9999)}"
        message[:duration_ms] = rand(1..100)
        puts "  🔍 TRACE: span #{message[:span_id]} took #{message[:duration_ms]}ms"
      end

      # Track message counts
      @mutex.synchronize do
        @message_counts[message[:type]] += 1
      end

      emit(message)
    end

    # Batch messages for efficient storage
    batch 5

    # Store batches
    consumer :store_batch do |batch|
      puts "\n💾 Storing batch of #{batch.size} messages:"
      type_counts = batch.group_by { |m| m[:type] }.transform_values(&:size)
      type_counts.each do |type, count|
        puts "   - #{count} #{type} message(s)"
      end

      # Simulate writing to database
      puts "   ✓ Batch written to database"
    end

    after_run do
      puts "\n" + "="*60
      puts "MESSAGE ROUTER STATISTICS"
      puts "="*60

      total = @message_counts.values.sum
      @message_counts.sort_by { |_, count| -count }.each do |type, count|
        percentage = (count * 100.0 / total).round(1)
        icon = case type
               when 'log' then '📋'
               when 'alert' then '🚨'
               when 'metric' then '📊'
               when 'event' then '⚡'
               when 'trace' then '🔍'
               else '❓'
               end
        puts "#{icon} #{type.ljust(10)} #{count.to_s.rjust(3)} messages (#{percentage}%)"
      end

      puts "\nTotal messages routed: #{total}"
      puts "Message routing complete!"
      puts "="*60
    end
  end
end

# Run if executed directly
if __FILE__ == $PROGRAM_NAME
  MessageRouterExample.new.run
end

