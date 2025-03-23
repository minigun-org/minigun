# frozen_string_literal: true

require 'minigun'

class PriorityProcessingExample
  include Minigun::DSL

  pipeline do
    producer :user_producer do
      # Simulate User.find_each
      users = [
        { id: 1, name: 'Alice', email: 'alice@example.com', vip: true },
        { id: 2, name: 'Bob', email: 'bob@example.com', vip: false },
        { id: 3, name: 'Charlie', email: 'charlie@example.com', vip: true },
        { id: 4, name: 'Dave', email: 'dave@example.com', vip: false }
      ]

      users.each do |user|
        emit(user)

        # Route VIP users to a high priority queue
        emit_to_queue(:high_priority, user) if user[:vip]
      end
    end

    # This processor handles both default and high priority users
    processor :email_processor, threads: 2, queues: %i[default high_priority] do |user|
      puts "Generating email for #{user[:name]} (VIP: #{user[:vip]})"

      # Create an email based on user type
      email = {
        user: user,
        type: user[:vip] ? 'vip_welcome' : 'standard_welcome'
      }

      emit(email)
    end

    # Regular handling for emails
    accumulator :email_accumulator, from: :email_processor do |email|
      @emails ||= {}
      @emails[email[:type]] ||= []
      @emails[email[:type]] << email

      # Emit batches by email type when they reach the threshold
      @emails.each do |type, batch|
        if batch.size >= 2 # Using 2 instead of 50 for the example
          emit_to_queue(type.to_sym, batch.dup)
          batch.clear
        end
      end
    end

    # Handle newsletter emails separately
    consumer :newsletter_sender, queues: [:newsletter] do |emails|
      puts "Sending #{emails.size} newsletter emails"
      emails.each { |email| puts "  Newsletter for: #{email[:user][:email]}" }
    end

    # Handle transaction emails separately
    consumer :transaction_sender, queues: [:transaction] do |emails|
      puts "Sending #{emails.size} transaction emails"
      emails.each { |email| puts "  Transaction for: #{email[:user][:email]}" }
    end

    # Handle vip welcome emails separately
    consumer :vip_sender, queues: [:vip_welcome] do |emails|
      puts "Sending #{emails.size} VIP welcome emails"
      emails.each { |email| puts "  VIP email for: #{email[:user][:email]}" }
    end

    # Handle standard welcome emails
    consumer :standard_sender, queues: [:standard_welcome] do |emails|
      puts "Sending #{emails.size} standard welcome emails"
      emails.each { |email| puts "  Standard email for: #{email[:user][:email]}" }
    end

    # Handle all other types
    consumer :general_sender, queues: [:default] do |emails|
      puts "Sending #{emails.size} generic emails"
      emails.each { |email| puts "  Generic email for: #{email[:user][:email]}" }
    end
  end
end

# Run the task
PriorityProcessingExample.new.run if __FILE__ == $PROGRAM_NAME
