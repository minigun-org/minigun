# frozen_string_literal: true

require 'minigun'

class BranchingExample
  include Minigun::DSL

  # Configuration
  max_threads 1
  max_processes 1
  batch_size 2

  # Sample User class for the example
  class User
    attr_reader :id, :name, :email, :preferences

    def initialize(id, name, email, preferences = {})
      @id = id
      @name = name
      @email = email
      @preferences = preferences
    end
  end

  # Pipeline definition
  pipeline do
    producer :user_producer do
      puts 'Generating users...'
      users = [
        User.new(1, 'Alice', 'alice@example.com', { email_notifications: true }),
        User.new(2, 'Bob', 'bob@example.com', { email_notifications: true }),
        User.new(3, 'Charlie', 'charlie@example.com', { email_notifications: false }),
        User.new(4, 'Diana', 'diana@example.com', { email_notifications: true })
      ]

      users.each do |user|
        puts "Producing user: #{user.name}"
        emit(user)
      end
    end

    # Branch 1: Email processing
    processor :email_processor, to: :email_accumulator do |user|
      if user.preferences[:email_notifications]
        puts "Generating email for #{user.name}"
        email = { to: user.email, subject: 'Newsletter', body: "Hello #{user.name}!" }
        emit(email)
      end
    end

    # Branch 2: Notification processing
    processor :notification_processor, to: :notification_sender do |user|
      puts "Generating notification for #{user.name}"
      notification = { user_id: user.id, message: "Welcome back, #{user.name}!" }
      emit(notification)
    end

    # Email branch continues
    accumulator :email_accumulator do |email|
      @emails ||= []
      @emails << email

      if @emails.size >= batch_size
        puts "Batching #{@emails.size} emails"
        batch = @emails.dup
        @emails.clear
        emit(batch)
      end
    end

    # Email sending
    consumer :email_sender do |emails|
      puts "Sending batch of #{emails.size} emails"
      emails.each do |email|
        puts "Sending email to #{email[:to]}: '#{email[:subject]}'"
      end
    end

    # Notification sending
    consumer :notification_sender do |notification|
      puts "Sending notification to user #{notification[:user_id]}: '#{notification[:message]}'"
    end
  end

  before_run do
    puts 'Starting branching task...'
  end

  after_run do
    puts 'Branching task completed!'
  end
end

# Run the task if executed directly
BranchingExample.new.run if __FILE__ == $PROGRAM_NAME
