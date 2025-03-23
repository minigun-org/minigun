# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'CowForkExample' do
  let(:output) { StringIO.new }
  let(:original_stdout) { $stdout }

  before do
    $stdout = output
  end

  after do
    $stdout = original_stdout
  end

  it 'executes the COW fork pipeline correctly' do
    # Load the example file
    load File.join(File.dirname(__FILE__), '../../../examples/cow_fork_example.rb')
    
    # Create an instance of the class
    task = CowForkExample.new
    
    # Configure for testing
    task.class._minigun_task.config[:fork_mode] = :never
    task.class._minigun_task.config[:max_threads] = 1
    
    # Run the task
    task.run

    # Verify the task output
    output_string = output.string
    
    # Check that batches were generated
    expect(output_string).to include("Generating batch of 2 items")
    
    # Check that items were processed
    expect(output_string).to include("Processing batch of 2 items")
    expect(output_string).to include("Items: 1, 2")
    expect(output_string).to include("Items: 3, 4")
    expect(output_string).to include("Items: 5, 6")
    expect(output_string).to include("Items: 7, 8")
    expect(output_string).to include("Items: 9, 10")
    
    # Check that values were summed and averaged
    expect(output_string).to include("Processing complete:")
  end

  it 'has the correct COW fork pipeline structure' do
    # Load the example file
    load File.join(File.dirname(__FILE__), '../../../examples/cow_fork_example.rb')
    
    # Get the task object directly
    task_obj = CowForkExample._minigun_task

    # Verify that the processor blocks are defined
    expect(task_obj.stage_blocks.keys).to include(:generate_data, :process_batch)
    
    # Verify that the pipeline stages are defined
    expect(task_obj.pipeline.size).to eq(2)
    
    # Check the fork stage
    process_batch = task_obj.pipeline.find { |s| s[:name] == :process_batch }
    expect(process_batch[:fork]).to eq(:cow)
    
    # Verify that the hooks are defined
    expect(task_obj.hooks[:before_fork]).to be_a(Array)
    expect(task_obj.hooks[:before_fork].size).to eq(1)
    
    expect(task_obj.hooks[:after_fork]).to be_a(Array)
    expect(task_obj.hooks[:after_fork].size).to eq(1)
  end
end