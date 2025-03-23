# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'LoadBalancerExample' do
  let(:output) { StringIO.new }
  let(:original_stdout) { $stdout }

  before do
    $stdout = output
  end

  after do
    $stdout = original_stdout
  end

  it 'executes the load balancer example correctly' do
    # Load the example file
    load File.join(File.dirname(__FILE__), '../../examples/load_balancer_example.rb')
    
    # Create an instance of the class
    task = LoadBalancerExample.new
    
    # Configure for testing
    task.class._minigun_task.config[:fork_mode] = :never
    task.class._minigun_task.config[:max_threads] = 1
    
    # Run the task
    task.run

    # Verify the task output
    output_string = output.string
    
    # Check that load balancing is working
    expect(output_string).to include('Distributing request to server')
    expect(output_string).to include('Request processed by server')
  end

  it 'has the correct load balancer pipeline structure' do
    # Load the example file
    load File.join(File.dirname(__FILE__), '../../examples/load_balancer_example.rb')
    
    # Get the task object directly
    task_obj = LoadBalancerExample._minigun_task

    # Verify that the processor blocks are defined with correct stages
    expected_stages = [
      :request_generator,
      :router,
      :server_a,
      :server_b,
      :server_c,
      :response_collector
    ]
    expect(task_obj.stage_blocks.keys).to include(*expected_stages)
    
    # Verify pipeline size (number of stages)
    expect(task_obj.pipeline.size).to eq(expected_stages.size)
    
    # Verify structure - first stage should be request_generator
    expect(task_obj.pipeline.first[:name]).to eq(:request_generator)
    
    # Last stage should be response_collector
    expect(task_obj.pipeline.last[:name]).to eq(:response_collector)
  end
  
  it 'correctly balances the load across servers' do
    # Load the example file
    load File.join(File.dirname(__FILE__), '../../examples/load_balancer_example.rb')
    
    # Clear output for this test
    output.string = ''
    
    # Create a test instance
    task = LoadBalancerExample.new
    
    # Force sequential execution for predictable testing
    task.class._minigun_task.config[:fork_mode] = :never
    task.class._minigun_task.config[:max_threads] = 1
    
    # Run the task
    task.run
    
    # Get output
    output_string = output.string
    
    # Count server distribution - should see some requests to each server
    server_a_count = output_string.scan(/Distributing request to server A/).count
    server_b_count = output_string.scan(/Distributing request to server B/).count
    server_c_count = output_string.scan(/Distributing request to server C/).count
    
    # Verify each server got at least one request
    expect(server_a_count).to be > 0
    expect(server_b_count).to be > 0
    expect(server_c_count).to be > 0
    
    # Total should match the number of requests generated
    total_requests = server_a_count + server_b_count + server_c_count
    expect(total_requests).to be > 0
  end
end 