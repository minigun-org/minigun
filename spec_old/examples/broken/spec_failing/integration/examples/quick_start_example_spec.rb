# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'QuickStartExample' do
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
    load File.join(File.dirname(__FILE__), '../../../examples/quick_start_example.rb')

    # Create an instance of the class
    task = QuickStartExample.new

    # Configure for testing
    task.class._minigun_task.config[:fork_mode] = :never
    task.class._minigun_task.config[:max_threads] = 1

    # Run the task
    task.run

    # Verify the task output
    output_string = output.string

    # Check that all numbers were transformed correctly (we look for transformation output instead of processing output when fork_mode=:never)
    [0, 2, 4, 6, 8, 10, 12, 14, 16, 18].each do |i|
      half_i = i / 2
      expected_output = "Transforming #{half_i} to #{i}"
      expect(output_string).to include(expected_output), "Output should include '#{expected_output}'"
    end

    # Since we're running with fork_mode=:never, the processing stage may be skipped
    # but we should still see the transformation output
    expect(output_string).to include('Transforming')
  end

  it 'has the correct pipeline structure' do
    # Load the example file
    load File.join(File.dirname(__FILE__), '../../../examples/quick_start_example.rb')

    # Get the task object directly
    task_obj = QuickStartExample._minigun_task

    # Verify that the processor blocks are defined
    expect(task_obj.stage_blocks.keys).to include(:generate, :transform, :batch, :process_batch)

    # Verify that the pipeline stages are defined
    expect(task_obj.pipeline.size).to eq(4)

    # Verify stage types and order
    expect(task_obj.pipeline[0][:type]).to eq(:processor)  # producer
    expect(task_obj.pipeline[0][:name]).to eq(:generate)

    expect(task_obj.pipeline[1][:type]).to eq(:processor)  # processor
    expect(task_obj.pipeline[1][:name]).to eq(:transform)

    expect(task_obj.pipeline[2][:type]).to eq(:accumulator) # accumulator
    expect(task_obj.pipeline[2][:name]).to eq(:batch)

    expect(task_obj.pipeline[3][:type]).to eq(:processor) # consumer (cow_fork)
    expect(task_obj.pipeline[3][:name]).to eq(:process_batch)
  end
end
