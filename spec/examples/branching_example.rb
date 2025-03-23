# frozen_string_literal: true

require 'minigun'

class BranchingExample
  include Minigun::DSL

  pipeline do
    # Producer emits to multiple processors
    producer :user_producer, to: %i[email_processor notification_processor] do
      # Simulate User.find_each
      users = [
        { id: 1, name: 'Alice', email: 'alice@example.com' },
        { id: 2, name: 'Bob', email: 'bob@example.com' },
        { id: 3, name: 'Charlie', email: 'charlie@example.com' }
      ]

      users.each do |user|
        emit(user)
      end
    end

    # These processors receive data from the same producer
    processor :email_processor, from: :user_producer do |user|
      puts "Generating email for #{user[:name]}"
      emit({ user: user, template: 'welcome_email' })
    end

    processor :notification_processor, from: :user_producer do |user|
      puts "Generating notification for #{user[:name]}"
      emit({ user: user, type: 'welcome_notification' })
    end

    # Connect the email processor to an accumulator
    accumulator :email_accumulator, from: :email_processor do |email|
      @emails ||= []
      @emails << email

      if @emails.size >= 2 # Using 2 instead of 100 for the example
        batch = @emails.dup
        @emails.clear
        emit(batch)
      end
    end

    # Process accumulated emails
    cow_fork :email_sender, from: :email_accumulator, processes: 2 do |emails|
      puts "Processing #{emails.size} emails in a forked process"
      emails.each { |email| puts "Sending email to #{email[:user][:email]}" }
    end

    # Process notifications directly
    consumer :notification_sender, from: :notification_processor do |notification|
      puts "Sending notification to #{notification[:user][:name]}"
    end
  end
end

# Run the task
BranchingExample.new.run if __FILE__ == $PROGRAM_NAME
