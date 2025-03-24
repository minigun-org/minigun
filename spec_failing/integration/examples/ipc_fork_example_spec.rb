# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'IpcForkExample' do
  let(:output) { StringIO.new }
  let(:original_stdout) { $stdout }

  before do
    $stdout = output
  end

  after do
    $stdout = original_stdout
  end

  it 'executes the IPC fork pipeline correctly' do
    # Load the example file
    load File.join(File.dirname(__FILE__), '../../../examples/ipc_fork_example.rb')

    # Create an instance of the class
    task = IpcForkExample.new

    # Configure for testing
    task.class._minigun_task.config[:fork_mode] = :never
    task.class._minigun_task.config[:max_threads] = 1

    # Run the task
    task.run

    # Verify the task output
    output_string = output.string

    # Check that batches were generated
    expect(output_string).to include('Generating IPC batch of 3 items')

    # Check that the pipeline completed
    expect(output_string).to include('IPC processing complete: all batches processed')
  end

  it 'has the correct IPC fork pipeline structure' do
    # Load the example file
    load File.join(File.dirname(__FILE__), '../../../examples/ipc_fork_example.rb')

    # Get the task object directly
    task_obj = IpcForkExample._minigun_task

    # Verify that the processor blocks are defined
    expect(task_obj.stage_blocks.keys).to include(:generate_data, :process_batch, :verify_results)

    # Verify that the pipeline stages are defined
    expect(task_obj.pipeline.size).to eq(4)

    # Check the IPC fork stage
    process_batch = task_obj.pipeline.find { |s| s[:name] == :process_batch }
    expect(process_batch[:fork]).to eq(:ipc)

    # Check the configuration
    expect(task_obj.config[:pipe_timeout]).to eq(60)
    expect(task_obj.config[:max_chunk_size]).to eq(2_000_000)
    expect(task_obj.config[:use_compression]).to be(true)
    expect(task_obj.config[:gc_probability]).to eq(0.2)

    # Verify that the hooks are defined
    expect(task_obj.hooks[:before_fork]).to be_a(Array)
    expect(task_obj.hooks[:before_fork].size).to eq(1)

    expect(task_obj.hooks[:after_fork]).to be_a(Array)
    expect(task_obj.hooks[:after_fork].size).to eq(1)
  end
end
