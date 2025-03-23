# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'BranchingExample' do
  let(:output) { StringIO.new }
  let(:original_stdout) { $stdout }

  before do
    $stdout = output
  end

  after do
    $stdout = original_stdout
  end

  it 'executes the branching pipeline correctly' do
    # Load the example file
    load File.join(File.dirname(__FILE__), '../../../examples/branching_example.rb')

    # Create an instance of the class
    task = BranchingExample.new

    # Configure for testing
    task.class._minigun_task.config[:fork_mode] = :never
    task.class._minigun_task.config[:max_threads] = 1

    # Run the task
    task.run

    # Verify the task output
    output_string = output.string

    # Check that users were processed correctly in both branches
    expect(output_string).to include('Generating email for')
    expect(output_string).to include('Generating notification for')
    expect(output_string).to include('Processing emails in a forked process')
    expect(output_string).to include('Sending notification to')
    expect(output_string).to include('Sending email to')
  end

  it 'has the correct branching pipeline structure' do
    # Load the example file
    load File.join(File.dirname(__FILE__), '../../../examples/branching_example.rb')

    # Get the task object directly
    task_obj = BranchingExample._minigun_task

    # Verify that the processor blocks are defined
    expected_stages = %i[
      user_producer
      email_processor
      notification_processor
      email_accumulator
      email_sender
      notification_sender
    ]
    expect(task_obj.stage_blocks.keys).to include(*expected_stages)

    # Verify that the pipeline stages are defined
    expect(task_obj.pipeline.size).to eq(expected_stages.size)

    # Verify producer connects to both processors
    producer = task_obj.pipeline.find { |s| s[:name] == :user_producer }
    expect(producer[:to]).to include(:email_processor, :notification_processor)

    # Verify email path
    email_processor = task_obj.pipeline.find { |s| s[:name] == :email_processor }
    expect(email_processor[:from]).to eq(:user_producer)

    email_accumulator = task_obj.pipeline.find { |s| s[:name] == :email_accumulator }
    expect(email_accumulator[:from]).to eq(:email_processor)

    email_sender = task_obj.pipeline.find { |s| s[:name] == :email_sender }
    expect(email_sender[:from]).to eq(:email_accumulator)

    # Verify notification path
    notification_processor = task_obj.pipeline.find { |s| s[:name] == :notification_processor }
    expect(notification_processor[:from]).to eq(:user_producer)

    notification_sender = task_obj.pipeline.find { |s| s[:name] == :notification_sender }
    expect(notification_sender[:from]).to eq(:notification_processor)
  end
end
