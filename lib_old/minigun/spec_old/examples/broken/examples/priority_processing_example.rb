# frozen_string_literal: true

require 'minigun'

class PriorityProcessingExample
  include Minigun::DSL

  # Configuration
  max_threads 2
  max_processes 1
  batch_size 2

  # Pipeline definition with priority-based routing
  pipeline do
    producer :user_producer do
      puts 'Generating user emails...'

      # Sample users with different VIP status and email types
      users = [
        { name: 'Alice', email: 'alice@example.com', vip: true, email_type: 'transaction' },
        { name: 'Bob', email: 'bob@example.com', vip: false, email_type: 'newsletter' },
        { name: 'Charlie', email: 'charlie@example.com', vip: false, email_type: 'transaction' },
        { name: 'Diana', email: 'diana@example.com', vip: true, email_type: 'newsletter' },
        { name: 'Eva', email: 'eva@example.com', vip: false, email_type: 'general' },
        { name: 'Frank', email: 'frank@example.com', vip: true, email_type: 'general' },
        { name: 'Grace', email: 'grace@example.com', vip: false, email_type: 'transaction' },
        { name: 'Henry', email: 'henry@example.com', vip: false, email_type: 'newsletter' }
      ]

      users.each do |user|
        puts "Generating email for #{user[:name]} (VIP: #{user[:vip]})"
        emit(user)
      end
    end

    # Process all emails
    processor :email_processor do |user|
      # Create an email object
      email = {
        to: user[:email],
        name: user[:name],
        subject: "#{user[:email_type].capitalize} email for #{user[:name]}",
        body: "Hello #{user[:name]}, here's your #{user[:email_type]} email!",
        vip: user[:vip],
        type: user[:email_type]
      }

      puts "Processing email for #{user[:name]}: #{email[:subject]}"
      emit(email)
    end

    # Accumulate emails by type
    accumulator :email_accumulator do |email|
      @emails ||= {}
      @emails[email[:type]] ||= []
      @emails[email[:type]] << email

      # Check if we have enough emails of any type to send
      @emails.each do |type, emails|
        next unless emails.size >= batch_size

        batch = emails.dup
        @emails[type].clear

        # Route to the appropriate queue based on type
        queue = case type
                when 'newsletter' then :newsletter_sender
                when 'transaction' then :transaction_sender
                else
                  if batch.any? { |e| e[:vip] }
                    :vip_sender
                  elsif type == 'general'
                    :general_sender
                  else
                    :standard_sender
                  end
                end

        puts "Batching #{batch.size} #{type} emails to #{queue}"
        emit_to_queue(queue, batch)
      end
    end

    # Different consumers for different priority levels
    consumer :newsletter_sender, from: :email_accumulator do |batch|
      puts "NEWSLETTER: Processing batch of #{batch.size} newsletter emails (LOW PRIORITY)"
      batch.each do |email|
        puts "NEWSLETTER: Sending to #{email[:name]} <#{email[:to]}>"
      end
    end

    consumer :transaction_sender, from: :email_accumulator do |batch|
      puts "TRANSACTION: Processing batch of #{batch.size} transaction emails (HIGH PRIORITY)"
      batch.each do |email|
        puts "TRANSACTION: Sending to #{email[:name]} <#{email[:to]}>"
      end
    end

    consumer :vip_sender, from: :email_accumulator do |batch|
      puts "VIP: Processing batch of #{batch.size} VIP emails (HIGHEST PRIORITY)"
      batch.each do |email|
        puts "VIP: Sending to #{email[:name]} <#{email[:to]}>"
      end
    end

    consumer :standard_sender, from: :email_accumulator do |batch|
      puts "STANDARD: Processing batch of #{batch.size} standard emails (MEDIUM PRIORITY)"
      batch.each do |email|
        puts "STANDARD: Sending to #{email[:name]} <#{email[:to]}>"
      end
    end

    consumer :general_sender, from: :email_accumulator do |batch|
      puts "GENERAL: Processing batch of #{batch.size} general emails (LOWEST PRIORITY)"
      batch.each do |email|
        puts "GENERAL: Sending to #{email[:name]} <#{email[:to]}>"
      end
    end
  end

  before_run do
    puts 'Starting priority email processing...'
  end

  after_run do
    puts 'Priority email processing completed!'
  end
end

# Run the task if executed directly
PriorityProcessingExample.new.run if __FILE__ == $PROGRAM_NAME
