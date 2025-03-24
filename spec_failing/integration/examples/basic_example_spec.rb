# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'BasicExample' do
  let(:output) { StringIO.new }
  let(:original_stdout) { $stdout }

  before do
    $stdout = output
  end

  after do
    $stdout = original_stdout
  end

  it 'executes the pipeline correctly' do
    # Load the example file
    load File.join(File.dirname(__FILE__), '../../../examples/basic_example.rb')

    # Create an instance of the class
    task = BasicExample.new

    # Verify pipeline setup - DEBUG
    puts "Pipeline definition: #{BasicExample._minigun_task.pipeline_definition.inspect}"
    puts "Stage blocks: #{BasicExample._minigun_task.stage_blocks.keys.inspect}"

    # Configure for testing
    task.class._minigun_task.config[:fork_mode] = :never
    task.class._minigun_task.config[:max_threads] = 1

    # Run the task
    task.run

    # Verify the task output
    output_string = output.string

    # Check for expected output
    expect(output_string).to include('Starting task...')
    expect(output_string).to include('Task completed!')

    # With fork_mode=:never, we should have seen at least some of the pipeline stages working
    expect(output_string).to include('Producing')
    expect(output_string).to include('Doubling')
  end

  it 'has the correct pipeline structure' do
    # Load the example file
    load File.join(File.dirname(__FILE__), '../../../examples/basic_example.rb')

    # Get the task object directly
    task_obj = BasicExample._minigun_task

    # Verify that the processor blocks are defined
    expect(task_obj.stage_blocks.keys).to include(:generate_numbers, :double_numbers, :filter_evens, :batch_numbers, :process_batch)

    # Verify that the pipeline stages are defined
    expect(task_obj.pipeline.size).to eq(5)

    # Verify stage types and order
    expect(task_obj.pipeline[0][:type]).to eq(:processor)
    expect(task_obj.pipeline[0][:name]).to eq(:generate_numbers)

    expect(task_obj.pipeline[1][:type]).to eq(:processor)
    expect(task_obj.pipeline[1][:name]).to eq(:double_numbers)

    expect(task_obj.pipeline[2][:type]).to eq(:processor)
    expect(task_obj.pipeline[2][:name]).to eq(:filter_evens)

    expect(task_obj.pipeline[3][:type]).to eq(:accumulator)
    expect(task_obj.pipeline[3][:name]).to eq(:batch_numbers)

    expect(task_obj.pipeline[4][:type]).to eq(:processor)
    expect(task_obj.pipeline[4][:name]).to eq(:process_batch)
  end

  it 'has the correct configuration' do
    # Load the example file
    load File.join(File.dirname(__FILE__), '../../../examples/basic_example.rb')

    # Get the task object directly
    task_obj = BasicExample._minigun_task

    # Verify configuration
    expect(task_obj.config[:max_threads]).to eq(4)
    expect(task_obj.config[:max_processes]).to eq(2)
    expect(task_obj.config[:batch_size]).to eq(50)
  end
end
