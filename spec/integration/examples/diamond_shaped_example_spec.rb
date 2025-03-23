# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'DiamondShapedExample' do
  let(:output) { StringIO.new }
  let(:original_stdout) { $stdout }

  before do
    $stdout = output
  end

  after do
    $stdout = original_stdout
  end

  it 'executes the diamond shaped pipeline correctly' do
    # Load the example file
    load File.join(File.dirname(__FILE__), '../../examples/diamond_shaped_example.rb')
    
    # Create an instance of the class
    task = DiamondShapedExample.new
    
    # Configure for testing
    task.class._minigun_task.config[:fork_mode] = :never
    task.class._minigun_task.config[:max_threads] = 1
    
    # Run the task
    task.run

    # Verify the task output
    output_string = output.string
    
    # Check that items were processed in the diamond pattern
    expect(output_string).to include('Producing item')
    expect(output_string).to include('Processing via branch')
    expect(output_string).to include('Merging and combining results')
  end

  it 'has the correct diamond shaped pipeline structure' do
    # Load the example file
    load File.join(File.dirname(__FILE__), '../../examples/diamond_shaped_example.rb')
    
    # Get the task object directly
    task_obj = DiamondShapedExample._minigun_task

    # Verify that the processor blocks are defined
    expected_stages = [
      :producer,
      :branch_a,
      :branch_b,
      :branch_c,
      :merge,
      :consumer
    ]
    expect(task_obj.stage_blocks.keys).to include(*expected_stages)
    
    # Verify pipeline size
    expect(task_obj.pipeline.size).to eq(expected_stages.size)
    
    # Verify producer outputs to all branches
    producer = task_obj.pipeline.find { |s| s[:name] == :producer }
    expect(producer[:to]).to include(:branch_a, :branch_b, :branch_c)
    
    # Verify merge inputs from all branches
    merge = task_obj.pipeline.find { |s| s[:name] == :merge }
    expect(merge[:from]).to include(:branch_a, :branch_b, :branch_c)
    
    # Verify consumer inputs from merge
    consumer = task_obj.pipeline.find { |s| s[:name] == :consumer }
    expect(consumer[:from]).to eq(:merge)
  end
  
  it 'correctly processes items through all branches' do
    # Load the example file
    load File.join(File.dirname(__FILE__), '../../examples/diamond_shaped_example.rb')
    
    # Create a test instance with fewer items for faster testing
    task = DiamondShapedExample.new
    
    # Configure for testing
    task.class._minigun_task.config[:fork_mode] = :never
    task.class._minigun_task.config[:max_threads] = 1
    
    # Clear output
    output.string = ''
    
    # Run the task
    task.run
    
    # Count branch processing in output
    output_string = output.string
    branch_a_count = output_string.scan(/Processing via branch A/).count
    branch_b_count = output_string.scan(/Processing via branch B/).count
    branch_c_count = output_string.scan(/Processing via branch C/).count
    
    # Verify each branch processed items
    expect(branch_a_count).to be > 0
    expect(branch_b_count).to be > 0
    expect(branch_c_count).to be > 0
    
    # Verify consumer received results
    expect(output_string.scan(/Consuming final result/).count).to be > 0
  end
end 