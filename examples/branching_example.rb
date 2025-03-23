# frozen_string_literal: true

require 'minigun'

class BranchingExample
  include Minigun::DSL

  # Configuration
  max_threads 2
  max_processes 2
  batch_size 3
  fork_mode :never

  # Instance method to access batch_size configuration
  def batch_size
    self.class._minigun_task.config[:batch_size]
  end

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
    # Define producer with connections to both processors
    producer :user_producer, to: [:email_processor, :notification_processor] do
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
    processor :email_processor, from: :user_producer, to: :email_accumulator do |user|
      # Handle fork_mode=:never case where we might receive a batch instead of a single user
      if user.is_a?(Array)
        user.each do |single_user|
          if single_user.preferences[:email_notifications]
            puts "Generating email for #{single_user.name}"
            email = { to: single_user.email, subject: 'Newsletter', body: "Hello #{single_user.name}!" }
            emit(email)
          end
        end
      else
        # Normal single user processing
        if user.preferences[:email_notifications]
          puts "Generating email for #{user.name}"
          email = { to: user.email, subject: 'Newsletter', body: "Hello #{user.name}!" }
          emit(email)
        end
      end
    end

    # Branch 2: Notification processing
    processor :notification_processor, from: :user_producer, to: :notification_sender do |user|
      # Handle fork_mode=:never case where we might receive a batch instead of a single user
      if user.is_a?(Array)
        user.each do |single_user|
          puts "Generating notification for #{single_user.name}"
          notification = { user_id: single_user.id, message: "Welcome back, #{single_user.name}!" }
          emit(notification)
        end
      else
        # Normal single user processing
        puts "Generating notification for #{user.name}"
        notification = { user_id: user.id, message: "Welcome back, #{user.name}!" }
        emit(notification)
      end
    end

    # Email branch continues
    accumulator :email_accumulator, from: :email_processor, to: :email_sender do |email|
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
    consumer :email_sender, from: :email_accumulator do |emails|
      # Check if we're dealing with a single email or a batch
      if emails.is_a?(Array)
        puts "Sending batch of #{emails.size} emails"
        emails.each do |email|
          puts "Sending email to #{email[:to]}: '#{email[:subject]}'"
        end
      else
        # Handle single email case for fork_mode=:never
        puts "Sending single email to #{emails[:to]}: '#{emails[:subject]}'"
      end
    end

    # Notification sending
    consumer :notification_sender, from: :notification_processor do |notification|
      # Handle both single notifications and arrays in test mode
      if notification.is_a?(Array)
        puts "Sending batch of #{notification.size} notifications"
        notification.each do |note|
          if note.is_a?(User)
            # Handle User objects directly
            puts "Sending notification to user #{note.id}: 'Welcome back, #{note.name}!'"
          else
            # Handle hash-based notifications
            puts "Sending notification to user #{note[:user_id]}: '#{note[:message]}'"
          end
        end
      else
        if notification.is_a?(User)
          # Handle User objects directly
          puts "Sending notification to user #{notification.id}: 'Welcome back, #{notification.name}!'"
        else
          # Normal single notification as hash
          puts "Sending notification to user #{notification[:user_id]}: '#{notification[:message]}'"
        end
      end
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
