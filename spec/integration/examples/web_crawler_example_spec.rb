# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'WebCrawlerExample' do
  let(:output) { StringIO.new }
  let(:original_stdout) { $stdout }

  before do
    $stdout = output
  end

  after do
    $stdout = original_stdout
  end

  it 'executes the web crawler example correctly' do
    # Load the example file
    load File.join(File.dirname(__FILE__), '../../examples/web_crawler_example.rb')
    
    # Create an instance of the class
    task = WebCrawlerExample.new
    
    # Configure for testing
    task.class._minigun_task.config[:fork_mode] = :never
    task.class._minigun_task.config[:max_threads] = 1
    
    # Run the task
    task.run

    # Verify the task output
    output_string = output.string
    
    # Check that the URLs were processed
    expect(output_string).to include('Starting crawl at')
    expect(output_string).to include('Discovered')
    expect(output_string).to include('Found')
    expect(output_string).to include('Processing page')
    expect(output_string).to include('Adding to database:')
  end

  it 'has the correct web crawler pipeline structure' do
    # Load the example file
    load File.join(File.dirname(__FILE__), '../../examples/web_crawler_example.rb')
    
    # Get the task object directly
    task_obj = WebCrawlerExample._minigun_task

    # Verify that the processor blocks are defined
    expected_stages = [
      :seed_urls,
      :fetch_url,
      :extract_links,
      :filter_urls,
      :process_page,
      :store_content
    ]
    expect(task_obj.stage_blocks.keys).to include(*expected_stages)
    
    # Verify that the pipeline stages are defined with correct structure
    expect(task_obj.pipeline.size).to eq(expected_stages.size)
    
    # Verify first stage is seed_urls
    expect(task_obj.pipeline.first[:name]).to eq(:seed_urls)
    
    # Verify fetch_url is configured for forking
    fetch_url = task_obj.pipeline.find { |s| s[:name] == :fetch_url }
    expect(fetch_url[:processes]).to be > 0
    
    # Verify extract_links is connected to fetch_url
    extract_links = task_obj.pipeline.find { |s| s[:name] == :extract_links }
    expect(extract_links[:from]).to eq(:fetch_url)
    
    # Verify filter_urls is connected to extract_links
    filter_urls = task_obj.pipeline.find { |s| s[:name] == :filter_urls }
    expect(filter_urls[:from]).to eq(:extract_links)
    
    # Verify store_content is the final stage
    expect(task_obj.pipeline.last[:name]).to eq(:store_content)
  end
  
  it 'correctly handles URL filtering and cycle detection' do
    # Load the example file
    load File.join(File.dirname(__FILE__), '../../examples/web_crawler_example.rb')
    
    # Create a test instance
    task = WebCrawlerExample.new
    
    # Force sequential execution for predictable testing
    task.class._minigun_task.config[:fork_mode] = :never
    task.class._minigun_task.config[:max_threads] = 1
    
    # Clear output for this test
    output.string = ''
    
    # Run the task
    task.run
    
    # Get output
    output_string = output.string
    
    # Verify URLs are filtered properly
    expect(output_string).to include('Filtering out')
    
    # Verify we're tracking visited URLs
    expect(output_string).to include('already visited')
  end
end 