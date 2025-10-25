# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'QueueBasedRoutingExample' do
  let(:output) { StringIO.new }
  let(:original_stdout) { $stdout }

  before do
    $stdout = output
  end

  after do
    $stdout = original_stdout
  end

  it 'executes the queue-based routing example correctly' do
    # Load the example file
    load File.join(File.dirname(__FILE__), '../../../examples/queue_based_routing_example.rb')

    # Create an instance of the class
    task = QueueBasedRoutingExample.new

    # Configure for testing
    task.class._minigun_task.config[:fork_mode] = :never
    task.class._minigun_task.config[:max_threads] = 1

    # Run the task
    task.run

    # Verify the task output
    output_string = output.string

    # Check that items were routed to appropriate queues
    expect(output_string).to include('Routing email to email_queue')
    expect(output_string).to include('Routing SMS to sms_queue')
    expect(output_string).to include('Routing push notification to push_queue')

    # Check that each handler processed its messages
    expect(output_string).to include('Processing email')
    expect(output_string).to include('Sending SMS')
    expect(output_string).to include('Sending push notification')
  end

  it 'has the correct queue-based routing pipeline structure' do
    # Load the example file
    load File.join(File.dirname(__FILE__), '../../../examples/queue_based_routing_example.rb')

    # Get the task object directly
    task_obj = QueueBasedRoutingExample._minigun_task

    # Verify that the processor blocks are defined
    expected_stages = %i[
      message_generator
      message_router
      email_handler
      sms_handler
      push_handler
    ]
    expect(task_obj.stage_blocks.keys).to include(*expected_stages)

    # Verify that the pipeline stages are defined
    expect(task_obj.pipeline.size).to eq(expected_stages.size)

    # Verify the queue routing setup
    message_router = task_obj.pipeline.find { |s| s[:name] == :message_router }
    expect(message_router[:from]).to eq(:message_generator)

    # Verify email handler subscribes to email queue
    email_handler = task_obj.pipeline.find { |s| s[:name] == :email_handler }
    expect(email_handler[:queues]).to include(:email_queue)

    # Verify SMS handler subscribes to SMS queue
    sms_handler = task_obj.pipeline.find { |s| s[:name] == :sms_handler }
    expect(sms_handler[:queues]).to include(:sms_queue)

    # Verify push handler subscribes to push queue
    push_handler = task_obj.pipeline.find { |s| s[:name] == :push_handler }
    expect(push_handler[:queues]).to include(:push_queue)
  end

  it 'correctly routes messages based on type' do
    # Load the example file
    load File.join(File.dirname(__FILE__), '../../../examples/queue_based_routing_example.rb')

    # Clear output
    output.string = ''

    # Create an instance
    task = QueueBasedRoutingExample.new

    # Configure for testing
    task.class._minigun_task.config[:fork_mode] = :never
    task.class._minigun_task.config[:max_threads] = 1

    # Run the task
    task.run

    # Get output
    output_string = output.string

    # Count message types
    email_count = output_string.scan('Processing email to:').count
    sms_count = output_string.scan('Sending SMS to:').count
    push_count = output_string.scan('Sending push notification to:').count

    # Verify all message types were processed
    expect(email_count).to be > 0
    expect(sms_count).to be > 0
    expect(push_count).to be > 0
  end
end
