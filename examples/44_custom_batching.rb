# frozen_string_literal: true

require_relative '../lib/minigun'

# Custom Batching Pattern
# Demonstrates flexible batching logic inside a regular stage with dynamic routing
class CustomBatchingExample
  include Minigun::DSL

  attr_reader :sent_counts

  def initialize
    @sent_counts = Hash.new(0)
    @mutex = Mutex.new
  end

  pipeline do
    producer :generate_emails do
      puts "\n" + "="*60
      puts "CUSTOM BATCHING: Generating Emails"
      puts "="*60

      # Generate mixed email types
      emails = [
        { id: 1, type: 'newsletter', to: 'user1@example.com', subject: 'Weekly Update' },
        { id: 2, type: 'transactional', to: 'user2@example.com', subject: 'Order Confirmation' },
        { id: 3, type: 'newsletter', to: 'user3@example.com', subject: 'Weekly Update' },
        { id: 4, type: 'promotional', to: 'user4@example.com', subject: 'Special Offer' },
        { id: 5, type: 'transactional', to: 'user5@example.com', subject: 'Password Reset' },
        { id: 6, type: 'newsletter', to: 'user6@example.com', subject: 'Weekly Update' },
        { id: 7, type: 'promotional', to: 'user7@example.com', subject: 'Flash Sale' },
        { id: 8, type: 'transactional', to: 'user8@example.com', subject: 'Shipping Notification' },
        { id: 9, type: 'newsletter', to: 'user9@example.com', subject: 'Weekly Update' },
        { id: 10, type: 'promotional', to: 'user10@example.com', subject: 'New Arrivals' },
        { id: 11, type: 'notification', to: 'user11@example.com', subject: 'Account Alert' },
        { id: 12, type: 'notification', to: 'user12@example.com', subject: 'Security Notice' }
      ]

      emails.each do |email|
        puts "📧 Generated #{email[:type]} email #{email[:id]}: #{email[:subject]}"
        emit(email)
      end
    end

    # Custom batching stage - batches by type with different thresholds
    stage :email_batcher do |email|
      # Initialize batch storage per type
      @batches ||= Hash.new { |h, k| h[k] = [] }
      @thresholds ||= {
        'transactional' => 2,  # Send immediately in small batches (urgent)
        'newsletter' => 3,     # Medium batch size
        'promotional' => 3,    # Medium batch size
        'notification' => 2    # Send quickly (important)
      }

      # Add email to its type's batch
      type = email[:type]
      @batches[type] << email
      threshold = @thresholds[type] || 5  # Default threshold

      puts "  → Buffered #{type} email (#{@batches[type].size}/#{threshold})"

      # Check if this type's batch is ready
      if @batches[type].size >= threshold
        batch = @batches[type].dup
        @batches[type].clear

        # Route to type-specific sender using emit_to_stage
        target_stage = :"#{type}_sender"
        puts "  ✓ Batch ready! Routing #{batch.size} #{type} emails to #{target_stage}"

        # Use emit_to_stage for direct routing to the target consumer
        emit_to_stage(target_stage, { type: type, batch: batch })
      end
    end

    # Type-specific consumers - one for each email type
    consumer :transactional_sender do |batch_info|
      type = batch_info[:type]
      batch = batch_info[:batch]

      @mutex.synchronize do
        @sent_counts[type] += batch.size
      end

      puts "⚡ TRANSACTIONAL: Sent batch of #{batch.size} emails:"
      batch.each do |email|
        puts "   - #{email[:id]}: #{email[:subject]} → #{email[:to]}"
      end
    end

    consumer :newsletter_sender do |batch_info|
      type = batch_info[:type]
      batch = batch_info[:batch]

      @mutex.synchronize do
        @sent_counts[type] += batch.size
      end

      puts "📰 NEWSLETTER: Sent batch of #{batch.size} emails:"
      batch.each do |email|
        puts "   - #{email[:id]}: #{email[:subject]} → #{email[:to]}"
      end
    end

    consumer :promotional_sender do |batch_info|
      type = batch_info[:type]
      batch = batch_info[:batch]

      @mutex.synchronize do
        @sent_counts[type] += batch.size
      end

      puts "💰 PROMOTIONAL: Sent batch of #{batch.size} emails:"
      batch.each do |email|
        puts "   - #{email[:id]}: #{email[:subject]} → #{email[:to]}"
      end
    end

    consumer :notification_sender do |batch_info|
      type = batch_info[:type]
      batch = batch_info[:batch]

      @mutex.synchronize do
        @sent_counts[type] += batch.size
      end

      puts "🔔 NOTIFICATION: Sent batch of #{batch.size} emails:"
      batch.each do |email|
        puts "   - #{email[:id]}: #{email[:subject]} → #{email[:to]}"
      end
    end

    after_run do
      # Flush any remaining batches
      if @batches && @batches.any? { |_, v| v.any? }
        puts "\n" + "="*60
        puts "FLUSHING REMAINING BATCHES"
        puts "="*60

        @batches.each do |type, emails|
          next if emails.empty?

          puts "#{type}: #{emails.size} email(s) remaining"
          # In a real system, we'd emit these to the appropriate sender
        end
      end

      puts "\n" + "="*60
      puts "CUSTOM BATCHING STATISTICS"
      puts "="*60

      total = @sent_counts.values.sum
      @sent_counts.sort_by { |type, _| type }.each do |type, count|
        percentage = total > 0 ? (count * 100.0 / total).round(1) : 0
        puts "#{type.ljust(20)} #{count} emails (#{percentage}%)"
      end

      puts "\nTotal emails sent: #{total}"
      puts "\nCustom batching complete!"
      puts "="*60
    end
  end
end

# Alternative example with more sophisticated routing
class AdvancedCustomBatchingExample
  include Minigun::DSL

  attr_reader :batch_stats

  def initialize
    @batch_stats = { batches_sent: 0, emails_sent: 0, types_processed: Set.new }
    @mutex = Mutex.new
  end

  pipeline do
    producer :generate_messages do
      puts "\n" + "="*60
      puts "ADVANCED CUSTOM BATCHING: Priority + Type Routing"
      puts "="*60

      # Generate messages with priority
      20.times do |i|
        message = {
          id: i + 1,
          type: ['email', 'sms', 'push'].sample,
          priority: ['low', 'normal', 'high', 'urgent'].sample,
          content: "Message #{i + 1}",
          timestamp: Time.now.to_i + i
        }

        icon = case message[:type]
               when 'email' then '📧'
               when 'sms' then '📱'
               when 'push' then '🔔'
               end

        puts "#{icon} Generated #{message[:type]} message (#{message[:priority]}): #{message[:id]}"
        emit(message)
      end
    end

    # Custom batching with multi-dimensional grouping
    stage :smart_batcher do |message|
      # Initialize batch storage with composite keys
      @batches ||= Hash.new { |h, k| h[k] = [] }

      # Batch by both type AND priority
      batch_key = "#{message[:type]}_#{message[:priority]}"
      @batches[batch_key] << message

      # Different thresholds based on priority
      threshold = case message[:priority]
                  when 'urgent' then 1  # Send immediately
                  when 'high' then 2
                  when 'normal' then 3
                  when 'low' then 5
                  end

      puts "  → Buffered #{batch_key} (#{@batches[batch_key].size}/#{threshold})"

      # Emit when threshold reached
      if @batches[batch_key].size >= threshold
        batch = @batches[batch_key].dup
        @batches[batch_key].clear

        puts "  ✓ Sending batch of #{batch.size} #{batch_key} messages"
        emit(batch)
      end
    end

    # Send batches
    consumer :send_batch do |batch|
      return if batch.empty?

      first = batch.first
      batch_key = "#{first[:type]}_#{first[:priority]}"

      @mutex.synchronize do
        @batch_stats[:batches_sent] += 1
        @batch_stats[:emails_sent] += batch.size
        @batch_stats[:types_processed].add(first[:type])
      end

      priority_icon = case first[:priority]
                      when 'urgent' then '🔥'
                      when 'high' then '⚡'
                      when 'normal' then '📝'
                      when 'low' then '🐌'
                      end

      puts "#{priority_icon} DELIVERED batch of #{batch.size} #{batch_key} messages"
    end

    after_run do
      puts "\n" + "="*60
      puts "ADVANCED BATCHING STATISTICS"
      puts "="*60
      puts "Batches sent: #{@batch_stats[:batches_sent]}"
      puts "Messages sent: #{@batch_stats[:emails_sent]}"
      puts "Message types: #{@batch_stats[:types_processed].to_a.join(', ')}"
      puts "\nAdvanced batching complete!"
      puts "="*60
    end
  end
end

# Run if executed directly
if __FILE__ == $PROGRAM_NAME
  puts "="*60
  puts "Example 1: Type-Based Custom Batching"
  puts "="*60
  CustomBatchingExample.new.run

  puts "\n\n"

  puts "="*60
  puts "Example 2: Priority + Type Custom Batching"
  puts "="*60
  AdvancedCustomBatchingExample.new.run
end

