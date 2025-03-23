# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'ConfiguredExample' do
  let(:output) { StringIO.new }
  let(:original_stdout) { $stdout }

  before do
    $stdout = output
  end

  after do
    $stdout = original_stdout
  end

  it 'executes the configured pipeline correctly' do
    # Load the example file
    load File.join(File.dirname(__FILE__), '../../examples/configured_example.rb')

    # Create an instance of the class
    task = ConfiguredExample.new

    # Configure for testing
    task.class._minigun_task.config[:fork_mode] = :never
    task.class._minigun_task.config[:max_threads] = 1

    # Run the task
    task.run

    # Verify the task output
    output_string = output.string

    # Check that the task was executed with the right configuration
    expect(output_string).to include('Starting configured task')
    expect(output_string).to include('Processing data')
    expect(output_string).to include('Task completed')
  end

  it 'loads the correct configuration' do
    # Load the example file
    load File.join(File.dirname(__FILE__), '../../examples/configured_example.rb')

    # Get the task object directly
    task_obj = ConfiguredExample._minigun_task

    # Verify the configuration values
    expect(task_obj.config[:max_threads]).to eq(5)
    expect(task_obj.config[:max_processes]).to eq(3)
    expect(task_obj.config[:batch_size]).to eq(20)
    expect(task_obj.config[:max_retries]).to eq(3)
    expect(task_obj.config[:retry_delay]).to eq(1.5)
  end

  it 'has the correct pipeline structure' do
    # Load the example file
    load File.join(File.dirname(__FILE__), '../../examples/configured_example.rb')

    # Get the task object directly
    task_obj = ConfiguredExample._minigun_task

    # Verify that the processor blocks are defined
    expected_stages = %i[
      source
      processor
      sink
    ]
    expect(task_obj.stage_blocks.keys).to include(*expected_stages)

    # Verify that the pipeline stages are defined
    expect(task_obj.pipeline.size).to eq(expected_stages.size)

    # Verify hooks are defined
    expect(task_obj.hooks[:before_run]).to be_a(Array)
    expect(task_obj.hooks[:before_run].size).to eq(1)

    expect(task_obj.hooks[:after_run]).to be_a(Array)
    expect(task_obj.hooks[:after_run].size).to eq(1)
  end

  it 'correctly implements the handler methods' do
    # Load the example file
    load File.join(File.dirname(__FILE__), '../../examples/configured_example.rb')

    # Create a test instance with override config
    task = ConfiguredExample.new(
      max_items: 5,
      batch_size: 2,
      environment: 'test'
    )

    # Verify instance config applied correctly
    expect(task.max_items).to eq(5)
    expect(task.batch_size).to eq(2)
    expect(task.environment).to eq('test')

    # Configure for testing
    task.class._minigun_task.config[:fork_mode] = :never
    task.class._minigun_task.config[:max_threads] = 1

    # Clear output
    output.string = ''

    # Run the task
    task.run

    # Verify the output with overridden config
    output_string = output.string
    expect(output_string).to include('Environment: test')
  end
end
