# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'ExplicitConnectionExample' do
  let(:output) { StringIO.new }
  let(:original_stdout) { $stdout }

  before do
    $stdout = output
  end

  after do
    $stdout = original_stdout
  end

  it 'executes the explicit connections pipeline correctly' do
    # Load the example file
    load File.join(File.dirname(__FILE__), '../../../examples/explicit_connection_example.rb')

    # Create an instance of the class
    task = ExplicitConnectionExample.new

    # Configure for testing
    task.class._minigun_task.config[:fork_mode] = :never
    task.class._minigun_task.config[:max_threads] = 1

    # Run the task
    task.run

    # Verify the task output
    output_string = output.string

    # Check that the pipeline executed with explicit connections
    expect(output_string).to include('Producing item')
    expect(output_string).to include('Processing item')
    expect(output_string).to include('Validating item')
    expect(output_string).to include('Consuming final result')
  end

  it 'has the correct explicit connections pipeline structure' do
    # Load the example file
    load File.join(File.dirname(__FILE__), '../../../examples/explicit_connection_example.rb')

    # Get the task object directly
    task_obj = ExplicitConnectionExample._minigun_task

    # Verify that the processor blocks are defined
    expected_stages = %i[
      producer
      processor
      validator
      consumer
    ]
    expect(task_obj.stage_blocks.keys).to include(*expected_stages)

    # Verify that the pipeline stages are defined
    expect(task_obj.pipeline.size).to eq(expected_stages.size)

    # Verify explicit connections
    producer = task_obj.pipeline.find { |s| s[:name] == :producer }
    expect(producer[:to]).to eq(:processor)

    processor = task_obj.pipeline.find { |s| s[:name] == :processor }
    expect(processor[:from]).to eq(:producer)
    expect(processor[:to]).to eq(:validator)

    validator = task_obj.pipeline.find { |s| s[:name] == :validator }
    expect(validator[:from]).to eq(:processor)
    expect(validator[:to]).to eq(:consumer)

    consumer = task_obj.pipeline.find { |s| s[:name] == :consumer }
    expect(consumer[:from]).to eq(:validator)
  end
end
