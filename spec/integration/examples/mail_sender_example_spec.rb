# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'MailSenderExample' do
  let(:output) { StringIO.new }
  let(:original_stdout) { $stdout }

  before do
    $stdout = output
  end

  after do
    $stdout = original_stdout
  end

  it 'executes the mail sender pipeline correctly' do
    # Load the example file
    load File.join(File.dirname(__FILE__), '../../../examples/mail_sender_example.rb')

    # Create an instance of the class
    task = MailSenderExample.new

    # Configure for testing
    task.class._minigun_task.config[:fork_mode] = :never
    task.class._minigun_task.config[:max_threads] = 1

    # Run the task
    task.run

    # Verify the task output
    output_string = output.string

    # Check that the producer generated users
    expect(output_string).to include('Starting producer for weekly_digest newsletter')
    expect(output_string).to include('Processing time range')

    # Check that users were filtered properly
    expect(output_string).to include('Filtering out user 4: Missing required fields')
    expect(output_string).to include('Filtering out user 5: Unsubscribed')
    expect(output_string).to include('User 1 passed filters')
    expect(output_string).to include('User 2 passed filters')
    expect(output_string).to include('User 3 passed filters')

    # Check that emails were batched and sent
    expect(output_string).to include('Sending batch of')
    expect(output_string).to include('Sending weekly_digest newsletter to')
  end

  it 'has the correct mail sender pipeline structure' do
    # Load the example file
    load File.join(File.dirname(__FILE__), '../../../examples/mail_sender_example.rb')

    # Get the task object directly
    task_obj = MailSenderExample._minigun_task

    # Verify that the processor blocks are defined
    expect(task_obj.stage_blocks.keys).to include(:customer_producer, :unsubscribed_filter, :email_batcher, :email_sender)

    # Verify that the pipeline stages are defined
    expect(task_obj.pipeline.size).to eq(4)

    # Check configuration
    expect(task_obj.config[:max_threads]).to eq(5)
    expect(task_obj.config[:max_processes]).to eq(2)
    expect(task_obj.config[:max_retries]).to eq(3)
    expect(task_obj.config[:batch_size]).to eq(50)

    # Check the hooks
    expect(task_obj.hooks[:before_run]).to be_a(Array)
    expect(task_obj.hooks[:before_run].size).to eq(1)

    expect(task_obj.hooks[:after_run]).to be_a(Array)
    expect(task_obj.hooks[:after_run].size).to eq(1)
  end

  it 'handles test mode correctly' do
    # Load the example file
    load File.join(File.dirname(__FILE__), '../../../examples/mail_sender_example.rb')

    # Create an instance of the class in test mode
    task = MailSenderExample.new(test_mode: true)

    # Configure for testing
    task.class._minigun_task.config[:fork_mode] = :never
    task.class._minigun_task.config[:max_threads] = 1

    # Verify the task in test mode
    expect(task.test_mode).to be true

    # The time_range_in_batches method should return a single range in test mode
    expect(task.send(:time_range_in_batches).size).to eq(1)
  end
end
