# frozen_string_literal: true

require 'minigun'

class MailSenderExample
  include Minigun::DSL

  # Configuration
  max_threads 2
  max_processes 1
  batch_size 3

  attr_reader :campaign_name, :test_mode

  def initialize(campaign_name = 'weekly_digest', test_mode = false)
    @campaign_name = campaign_name
    @test_mode = test_mode
    puts "MailSenderExample started for campaign: #{campaign_name}"
  end

  # Pipeline definition for an email sender
  pipeline do
    producer :customer_producer do
      puts "Starting producer for #{context.campaign_name} newsletter"

      # Sample customer data
      customers = [
        { id: 1, email: 'customer1@example.com', name: 'Alice', subscribed: true },
        { id: 2, email: 'customer2@example.com', name: 'Bob', subscribed: true },
        { id: 3, email: 'customer3@example.com', name: 'Charlie', subscribed: false },
        { id: 4, email: 'customer4@example.com', name: 'Diana', subscribed: true },
        { id: 5, email: 'customer5@example.com', name: 'Evan', subscribed: true },
        { id: 6, email: 'customer6@example.com', name: 'Fiona', subscribed: false },
        { id: 7, email: 'customer7@example.com', name: 'George', subscribed: true }
      ]

      puts "Found #{customers.size} customers for #{context.campaign_name} campaign"
      customers.each do |customer|
        puts "Processing customer: #{customer[:name]}"
        emit(customer)
      end
    end

    # Filter out unsubscribed customers
    processor :unsubscribed_filter do |customer|
      if customer[:subscribed]
        puts "Customer #{customer[:name]} is subscribed, sending email"

        email = {
          to: customer[:email],
          name: customer[:name],
          subject: "#{context.campaign_name.capitalize} Newsletter",
          body: "Hello #{customer[:name]}, here's your #{context.campaign_name} newsletter!"
        }

        emit(email)
      else
        puts "Customer #{customer[:name]} is unsubscribed, skipping"
      end
    end

    # Batch emails for more efficient sending
    accumulator :email_batcher do |email|
      @emails ||= []
      @emails << email

      if @emails.size >= batch_size
        puts "Batching #{@emails.size} emails for sending"
        batch = @emails.dup
        @emails.clear
        emit(batch)
      end
    end

    # Email sending consumer
    consumer :email_sender do |emails|
      if context.test_mode
        puts "TEST MODE: Would send #{emails.size} emails"
        emails.each do |email|
          puts "TEST: Email to #{email[:name]} <#{email[:to]}> with subject '#{email[:subject]}'"
        end
      else
        puts "Sending batch of #{emails.size} emails"
        emails.each do |email|
          puts "Sending email to #{email[:name]} <#{email[:to]}>: '#{email[:subject]}'"
          # In a real implementation, we would make an API call to an email service here
        end
      end
    end
  end

  after_run do
    puts "MailSenderExample finished for campaign: #{campaign_name}"
  end
end

# Run the task if executed directly
if __FILE__ == $PROGRAM_NAME
  # Normally: MailSenderExample.new('weekly_digest').run
  # For testing: Pass true as second param for test mode
  MailSenderExample.new('weekly_digest', false).run
end
