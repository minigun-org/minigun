# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'DataEtlExample' do
  let(:output) { StringIO.new }
  let(:original_stdout) { $stdout }

  before do
    $stdout = output
  end

  after do
    $stdout = original_stdout
  end

  it 'executes the data ETL pipeline correctly' do
    # Load the example file
    load File.join(File.dirname(__FILE__), '../../../examples/data_etl_example.rb')

    # Create an instance of the class
    task = DataEtlExample.new

    # Configure for testing
    task.class._minigun_task.config[:fork_mode] = :never
    task.class._minigun_task.config[:max_threads] = 1

    # Run the task
    task.run

    # Verify the task output
    output_string = output.string

    # Check ETL stages executed correctly
    expect(output_string).to include('Extracting data from source')
    expect(output_string).to include('Cleaning record')
    expect(output_string).to include('Transforming record')
    expect(output_string).to include('Loading batch of')
  end

  it 'has the correct data ETL pipeline structure' do
    # Load the example file
    load File.join(File.dirname(__FILE__), '../../../examples/data_etl_example.rb')

    # Get the task object directly
    task_obj = DataEtlExample._minigun_task

    # Verify that the processor blocks are defined
    expected_stages = %i[
      extract
      clean
      transform
      batch
      load
    ]
    expect(task_obj.stage_blocks.keys).to include(*expected_stages)

    # Verify that the pipeline stages are defined
    expect(task_obj.pipeline.size).to eq(expected_stages.size)

    # Verify pipeline structure
    extract = task_obj.pipeline.find { |s| s[:name] == :extract }
    expect(extract[:type]).to eq(:processor)

    clean = task_obj.pipeline.find { |s| s[:name] == :clean }
    expect(clean[:from]).to eq(:extract)

    transform = task_obj.pipeline.find { |s| s[:name] == :transform }
    expect(transform[:from]).to eq(:clean)

    batch = task_obj.pipeline.find { |s| s[:name] == :batch }
    expect(batch[:from]).to eq(:transform)

    load_stage = task_obj.pipeline.find { |s| s[:name] == :load }
    expect(load_stage[:from]).to eq(:batch)
  end

  it 'correctly processes records through the ETL stages' do
    # Load the example file
    load File.join(File.dirname(__FILE__), '../../../examples/data_etl_example.rb')

    # Create an instance and configure for testing
    task = DataEtlExample.new
    task.class._minigun_task.config[:fork_mode] = :never
    task.class._minigun_task.config[:max_threads] = 1

    # Clear output
    output.string = ''

    # Run the task
    task.run

    # Get output
    output_string = output.string

    # Verify record processing
    extract_count = output_string.scan('Extracting data from source').count
    transform_count = output_string.scan('Transforming record').count

    # Some records should be cleaned and transformed
    expect(extract_count).to be > 0
    expect(transform_count).to be > 0

    # Some records should be loaded in batches
    expect(output_string).to include('Loading batch of')
  end
end
