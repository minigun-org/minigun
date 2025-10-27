# frozen_string_literal: true

require 'minigun'

class QueueBasedRoutingExample
  include Minigun::DSL

  # Configuration
  max_threads 2
  max_processes 1
  batch_size 2

  # Pipeline definition for queue-based message routing
  pipeline do
    producer :message_generator do
      puts 'Generating messages of different types...'

      # Sample message types
      message_types = %w[log alert metric event notification]

      # Generate 20 random messages
      20.times do |i|
        message_type = message_types.sample
        message = {
          id: i + 1,
          type: message_type,
          content: "This is a #{message_type} message ##{i + 1}",
          timestamp: Time.now.to_i
        }

        puts "Generated message #{message[:id]} of type '#{message[:type]}'"
        emit(message)
      end
    end

    # Message router - routes to different queues based on message type
    processor :message_router do |message|
      puts "Routing message #{message[:id]} of type '#{message[:type]}'"

      # Route to specific queue based on message type
      case message[:type]
      when 'log'
        emit_to_queue(:log_processor, message)
      when 'alert'
        emit_to_queue(:alert_processor, message)
      when 'metric'
        emit_to_queue(:metric_processor, message)
      else
        # Default queue for other message types
        emit_to_queue(:default_processor, message)
      end
    end

    # Log processor
    processor :log_processor, from: :message_router, to: :archiver do |message|
      puts "LOG PROCESSOR: Processing log message #{message[:id]}"
      message[:processed_by] = 'log_processor'
      message[:log_level] = %w[info warn error].sample

      puts "LOG: [#{message[:log_level]}] #{message[:content]}"
      emit(message)
    end

    # Alert processor
    processor :alert_processor, from: :message_router, to: :notifier do |message|
      puts "ALERT PROCESSOR: Processing alert message #{message[:id]}"
      message[:processed_by] = 'alert_processor'
      message[:priority] = %w[low medium high critical].sample

      puts "ALERT: [#{message[:priority]}] #{message[:content]}"
      emit(message)
    end

    # Metric processor
    processor :metric_processor, from: :message_router, to: :aggregator do |message|
      puts "METRIC PROCESSOR: Processing metric message #{message[:id]}"
      message[:processed_by] = 'metric_processor'
      message[:value] = rand(1..100)
      message[:unit] = %w[bytes ms requests errors].sample

      puts "METRIC: #{message[:value]} #{message[:unit]} - #{message[:content]}"
      emit(message)
    end

    # Default processor
    processor :default_processor, from: :message_router, to: :archiver do |message|
      puts "DEFAULT PROCESSOR: Processing #{message[:type]} message #{message[:id]}"
      message[:processed_by] = 'default_processor'

      puts "DEFAULT: #{message[:content]}"
      emit(message)
    end

    # Notifier (for alerts)
    consumer :notifier, from: :alert_processor do |message|
      puts "NOTIFIER: Sending notification for alert #{message[:id]} [#{message[:priority]}]"

      # Simulate sending a notification
      if message[:priority] == 'critical'
        puts "NOTIFIER: Sending SMS and email for critical alert: #{message[:content]}"
      else
        puts "NOTIFIER: Sending email for alert: #{message[:content]}"
      end
    end

    # Aggregator (for metrics)
    accumulator :aggregator, from: :metric_processor do |message|
      @metrics ||= {}
      unit = message[:unit]

      @metrics[unit] ||= {
        count: 0,
        total: 0,
        messages: []
      }

      @metrics[unit][:count] += 1
      @metrics[unit][:total] += message[:value]
      @metrics[unit][:messages] << message

      # If we have enough metrics of one type, emit the batch
      if @metrics[unit][:count] >= batch_size
        batch = {
          unit: unit,
          count: @metrics[unit][:count],
          average: (@metrics[unit][:total] / @metrics[unit][:count].to_f).round(2),
          messages: @metrics[unit][:messages].dup
        }

        puts "AGGREGATOR: Batched #{batch[:count]} #{unit} metrics, average: #{batch[:average]}"

        # Clear the messages but keep running totals
        @metrics[unit][:messages] = []

        emit(batch)
      end
    end

    # Consumer for aggregated metrics
    consumer :metrics_reporter, from: :aggregator do |batch|
      puts "METRICS REPORTER: Processing batch of #{batch[:count]} #{batch[:unit]} metrics"
      puts "METRICS REPORTER: Average value: #{batch[:average]} #{batch[:unit]}"

      # Simulate storing to a time-series database
      puts 'METRICS REPORTER: Storing aggregated metrics to database'
    end

    # Archiver (for logs and default messages)
    consumer :archiver do |message|
      puts "ARCHIVER: Archiving #{message[:type]} message #{message[:id]}"
      puts "ARCHIVER: Message was processed by #{message[:processed_by]}"

      # Simulate archiving to storage
      puts "ARCHIVER: Message archived: #{message[:content]}"
    end
  end

  before_run do
    puts 'Starting queue-based message routing system...'
  end

  after_run do
    puts 'Queue-based message routing completed!'
  end
end

# Run the task if executed directly
QueueBasedRoutingExample.new.run if __FILE__ == $PROGRAM_NAME
