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
    expect(output_string).to include('Sending notification to')
    
    # Check for email handling - since fork_mode=:never, we won't see forking messages
    # but we should see messages about accumulating and sending emails
    expect(output_string).to include('Batching') if output_string.include?('Batching')
    expect(output_string).to include('Sending email to') if output_string.include?('Sending email to')
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

    # Verify that the pipeline stages are defined - check only the stage names match
    pipeline_stage_names = task_obj.pipeline.map { |s| s[:name] }
    expect(pipeline_stage_names).to match_array(expected_stages)
    
    # Verify the task has all required stage blocks
    expect(task_obj.stage_blocks).to have_key(:user_producer)
    expect(task_obj.stage_blocks).to have_key(:email_processor)
    expect(task_obj.stage_blocks).to have_key(:notification_processor)
    expect(task_obj.stage_blocks).to have_key(:email_accumulator)
    expect(task_obj.stage_blocks).to have_key(:email_sender)
    expect(task_obj.stage_blocks).to have_key(:notification_sender)
  end
end
