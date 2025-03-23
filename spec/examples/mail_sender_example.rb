# frozen_string_literal: true

require 'minigun'
require 'time'

class MailSenderExample
  include Minigun::DSL

  # Configure minigun settings
  max_threads 5
  max_processes 2
  max_retries 3
  batch_size 50

  attr_reader :campaign, :test_mode, :start_time, :end_time

  def initialize(campaign: 'weekly_digest', test_mode: false)
    @campaign = campaign
    @test_mode = test_mode
    @start_time = Time.now - (86_400 * 2) # 2 days ago
    @end_time = Time.now - 86_400 # 1 day ago

    # Sample user data for demonstration
    @users = [
      { id: 1, email: 'user1@example.com', display_email: 'User One <user1@example.com>', updated_at: Time.now - (86_400 * 1.5), newsletter_sent_at: nil },
      { id: 2, email: 'user2@example.com', display_email: 'User Two <user2@example.com>', updated_at: Time.now - (86_400 * 1.7), newsletter_sent_at: nil },
      { id: 3, email: 'user3@example.com', display_email: 'User Three <user3@example.com>', updated_at: Time.now - (86_400 * 1.2), newsletter_sent_at: Time.now - (86_400 * 5) },
      { id: 4, email: nil, display_email: nil, updated_at: Time.now - (86_400 * 1.8), newsletter_sent_at: nil },
      { id: 5, email: 'unsubscribed@example.com', display_email: 'Unsubscribed <unsubscribed@example.com>', updated_at: Time.now - (86_400 * 1.6), newsletter_sent_at: nil }
    ]

    # Sample unsubscribed users
    @unsubscribed = ['unsubscribed@example.com']
  end

  # Define the pipeline
  pipeline do
    producer :customer_producer do
      puts "Starting producer for #{campaign} newsletter"

      time_ranges = time_range_in_batches

      time_ranges.each do |range|
        puts "Processing time range #{format_time_range(range)}"
        count = 0

        eligible_users = @users.select { |user| user[:updated_at].between?(range.begin, range.end) }

        eligible_users.each do |user|
          emit(user)
          count += 1
        end

        puts "Produced #{count} customer users in time range #{format_time_range(range)}"
      end
    end

    processor :unsubscribed_filter do |user|
      # Skip objects without required fields
      if user[:id].nil? || user[:email].nil? || user[:display_email].nil?
        puts "Filtering out user #{user[:id]}: Missing required fields"
        user[:newsletter_sent_at] = Time.now
        next
      end

      # Check for unsubscribed emails
      if !test_mode && @unsubscribed.include?(user[:email])
        puts "Filtering out user #{user[:id]}: Unsubscribed"
        user[:newsletter_sent_at] = Time.now
        next
      end

      puts "User #{user[:id]} passed filters"
      emit(user)
    end

    # Batch users for delivery
    accumulator :email_batcher do |user|
      @batch ||= []
      @batch << user

      if @batch.size >= 2 # Using a smaller batch size for the example
        batch = @batch.dup
        @batch.clear
        emit(batch)
      end
    end

    # Send emails in batches
    consumer :email_sender do |batch|
      puts "Sending batch of #{batch.size} emails for campaign: #{campaign}"

      batch.each do |user|
        user[:newsletter_sent_at] = Time.now
        puts "Sending #{campaign} newsletter to #{user[:display_email]}"
        # In a real implementation, this would send the actual email
      end
    end
  end

  before_run do
    puts "#{self.class.name} started for campaign: #{campaign}"
  end

  after_run do
    puts "#{self.class.name} finished for campaign: #{campaign}"
  end

  private

  def time_range_in_batches
    range = start_time..end_time

    if test_mode
      [range]
    else
      # Calculate batch ranges based on 6-hour intervals
      result = []
      current_start = range.begin

      while current_start < range.end
        current_end = [current_start + 21_600, range.end].min # 6 hours in seconds
        result << (current_start..current_end)
        current_start = current_end
      end

      result
    end
  end

  def format_time_range(range)
    "#{format_time(range.begin)}..#{format_time(range.end)}"
  end

  def format_time(time)
    time&.strftime('%Y-%m-%d %H:%M:%S')
  end
end

# Run the example if this file is executed directly
if __FILE__ == $PROGRAM_NAME
  # Normal mode
  NewsletterPublisherExample.new.run

  # Test mode
  # NewsletterPublisherExample.new(test_mode: true).run
end
