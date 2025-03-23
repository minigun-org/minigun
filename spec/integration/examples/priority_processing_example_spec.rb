# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'PriorityProcessingExample' do
  let(:output) { StringIO.new }
  let(:original_stdout) { $stdout }

  before do
    $stdout = output
  end

  after do
    $stdout = original_stdout
  end

  it 'executes the priority processing pipeline correctly' do
    # Load the example file
    load File.join(File.dirname(__FILE__), '../../examples/priority_processing_example.rb')

    # Create an instance of the class
    task = PriorityProcessingExample.new

    # Configure for testing
    task.class._minigun_task.config[:fork_mode] = :never
    task.class._minigun_task.config[:max_threads] = 1

    # Run the task
    task.run

    # Verify the task output
    output_string = output.string

    # Check that VIP users were processed with priority
    expect(output_string).to include('Generating email for Alice (VIP: true)')
    expect(output_string).to include('Generating email for Charlie (VIP: true)')

    # Check that standard users were processed normally
    expect(output_string).to include('Generating email for Bob (VIP: false)')
    expect(output_string).to include('Generating email for Dave (VIP: false)')

    # Verify that emails were routed to the correct handlers
    expect(output_string).to include('Sending VIP welcome emails')
    expect(output_string).to include('Sending standard welcome emails')
  end

  it 'has the correct priority-based routing structure' do
    # Load the example file
    load File.join(File.dirname(__FILE__), '../../examples/priority_processing_example.rb')

    # Get the task object directly
    task_obj = PriorityProcessingExample._minigun_task

    # Verify that the processor blocks are defined
    expected_stages = %i[
      user_producer
      email_processor
      email_accumulator
      newsletter_sender
      transaction_sender
      vip_sender
      standard_sender
      general_sender
    ]
    expect(task_obj.stage_blocks.keys).to include(*expected_stages)

    # Verify pipeline size
    expect(task_obj.pipeline.size).to eq(expected_stages.size)

    # Verify queue setup for processor
    email_processor = task_obj.pipeline.find { |s| s[:name] == :email_processor }
    expect(email_processor[:queues]).to include(:default, :high_priority)
    expect(email_processor[:threads]).to eq(2)

    # Verify email consumer routing
    vip_sender = task_obj.pipeline.find { |s| s[:name] == :vip_sender }
    expect(vip_sender[:queues]).to include(:vip_welcome)

    standard_sender = task_obj.pipeline.find { |s| s[:name] == :standard_sender }
    expect(standard_sender[:queues]).to include(:standard_welcome)
  end

  it 'correctly routes VIP users to high priority queues' do
    # Load the example file
    load File.join(File.dirname(__FILE__), '../../examples/priority_processing_example.rb')

    # Create an instance
    task = PriorityProcessingExample.new

    # Configure for testing
    task.class._minigun_task.config[:fork_mode] = :never
    task.class._minigun_task.config[:max_threads] = 1

    # Clear output
    output.string = ''

    # Run the task
    task.run

    # Get output
    output_string = output.string

    # Verify VIP emails went to VIP sender
    vip_email_pattern = /VIP email for: (alice|charlie)@example.com/i
    vip_matches = output_string.scan(vip_email_pattern)
    expect(vip_matches.size).to be > 0

    # Verify standard emails went to standard sender
    std_email_pattern = /Standard email for: (bob|dave)@example.com/i
    std_matches = output_string.scan(std_email_pattern)
    expect(std_matches.size).to be > 0
  end
end
