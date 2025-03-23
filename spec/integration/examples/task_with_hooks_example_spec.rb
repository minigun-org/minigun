# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'TaskWithHooksExample' do
  let(:output) { StringIO.new }
  let(:original_stdout) { $stdout }

  before do
    $stdout = output
  end

  after do
    $stdout = original_stdout
  end

  it 'executes the pipeline with hooks correctly' do
    # Load the example file
    load File.join(File.dirname(__FILE__), '../../examples/task_with_hooks_example.rb')
    
    # Create an instance of the class
    task = TaskWithHooksExample.new
    
    # Configure for testing
    task.class._minigun_task.config[:fork_mode] = :never
    task.class._minigun_task.config[:max_threads] = 1
    
    # Run the task
    task.run

    # Verify the task output
    output_string = output.string
    
    # Check that all hooks were executed
    expect(output_string).to include('Before run hook executed')
    expect(output_string).to include('After run hook executed')
    
    # Check that stage hooks were executed
    expect(output_string).to include('Before stage hook')
    expect(output_string).to include('After stage hook')
    
    # Check that the pipeline executed
    expect(output_string).to include('Processing item')
    expect(output_string).to include('Consumer received')
  end

  it 'has the correct hooks defined' do
    # Load the example file
    load File.join(File.dirname(__FILE__), '../../examples/task_with_hooks_example.rb')
    
    # Get the task object directly
    task_obj = TaskWithHooksExample._minigun_task

    # Check the hooks
    expect(task_obj.hooks[:before_run]).to be_a(Array)
    expect(task_obj.hooks[:before_run].size).to eq(1)
    
    expect(task_obj.hooks[:after_run]).to be_a(Array)
    expect(task_obj.hooks[:after_run].size).to eq(1)
    
    expect(task_obj.hooks[:before_stage]).to be_a(Array)
    expect(task_obj.hooks[:before_stage].size).to eq(1)
    
    expect(task_obj.hooks[:after_stage]).to be_a(Array)
    expect(task_obj.hooks[:after_stage].size).to eq(1)
  end
  
  it 'has the correct pipeline structure' do
    # Load the example file
    load File.join(File.dirname(__FILE__), '../../examples/task_with_hooks_example.rb')
    
    # Get the task object directly
    task_obj = TaskWithHooksExample._minigun_task

    # Verify that the processor blocks are defined
    expected_stages = [
      :producer,
      :processor,
      :consumer
    ]
    expect(task_obj.stage_blocks.keys).to include(*expected_stages)
    
    # Verify that the pipeline stages are defined
    expect(task_obj.pipeline.size).to eq(expected_stages.size)
    
    # Verify pipeline structure
    producer = task_obj.pipeline.find { |s| s[:name] == :producer }
    expect(producer[:type]).to eq(:processor)
    
    processor = task_obj.pipeline.find { |s| s[:name] == :processor }
    expect(processor[:from]).to eq(:producer)
    
    consumer = task_obj.pipeline.find { |s| s[:name] == :consumer }
    expect(consumer[:from]).to eq(:processor)
  end
end 