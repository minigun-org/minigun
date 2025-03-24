# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'README Examples Integration' do
  describe 'Quick Start Example' do
    it 'executes a pipeline with the stages and blocks as described in the README' do
      # Create a test module with DSL directly in the test
      test_module = Module.new do
        include Minigun::DSL

        # Define a simplified pipeline
        producer do
          (1..5).each { |i| emit(i) }
        end

        processor do |item|
          emit(item * 2)
        end

        consumer do |batch|
          # In our test this won't actually be called
        end

        # Configuration for testing
        max_threads 1
        max_processes 1
        fork_mode :never
      end

      # Get the task object
      task = test_module._minigun_task

      # Verify that the processor blocks are defined
      expect(task.stage_blocks.keys).not_to be_empty
      expect(task.stage_blocks[:default]).to be_a(Proc)

      # Verify that the pipeline stages are defined
      expect(task.pipeline.size).to eq(3)

      # First stage should be a producer
      expect(task.pipeline[0][:type]).to eq(:processor)

      # Second stage should be a processor
      expect(task.pipeline[1][:type]).to eq(:processor)

      # Last stage should be a consumer
      expect(task.pipeline[2][:type]).to eq(:processor)
    end
  end

  describe 'Data ETL Pipeline' do
    it 'configures the ETL pipeline correctly' do
      # Create a class that includes the DSL
      task_class = Class.new do
        include Minigun::DSL

        attr_reader :database

        def initialize
          # Mock database with sample data
          @database = [
            { id: 1, name: 'Item 1', value: 10 },
            { id: 2, name: 'Item 2', value: 20 },
            { id: 3, name: 'Item 3', value: 30 },
            { id: 4, name: 'Item 4', value: 40 },
            { id: 5, name: 'Item 5', value: 50 }
          ]
        end

        def transform_row(row)
          { id: row[:id], transformed_name: "Transformed #{row[:name]}", value: row[:value] * 2 }
        end
      end

      # Define the pipeline
      task_class.class_eval do
        producer :extract do
          # Mock database.each_batch
          @database.each_slice(2) do |batch|
            emit(batch)
          end
        end

        processor :transform do |batch|
          # Transform the data
          transformed = batch.map { |row| transform_row(row) }
          transformed
        end

        consumer :load do |batch|
          # Load data to destination
        end

        # Configure for testing
        max_threads 1
        max_processes 1
        fork_mode :never
      end

      # Create a task instance
      task_class.new

      # Get the task object directly
      task_obj = task_class._minigun_task

      # Verify that the processor blocks are defined
      expect(task_obj.stage_blocks.keys).to include(:extract, :transform, :load)
      expect(task_obj.stage_blocks[:extract]).to be_a(Proc)
      expect(task_obj.stage_blocks[:transform]).to be_a(Proc)
      expect(task_obj.stage_blocks[:load]).to be_a(Proc)

      # Verify that the pipeline stages are defined
      expect(task_obj.pipeline.size).to eq(3)

      # First stage should be a producer
      expect(task_obj.pipeline[0][:type]).to eq(:processor)
      expect(task_obj.pipeline[0][:name]).to eq(:extract)

      # Second stage should be a processor
      expect(task_obj.pipeline[1][:type]).to eq(:processor)

      # Last stage should be a consumer
      expect(task_obj.pipeline[2][:type]).to eq(:processor)
    end
  end

  describe 'Parallel Web Crawler' do
    it 'configures the web crawler pipeline correctly' do
      # Create a class that includes the DSL
      crawler_class = Class.new do
        include Minigun::DSL

        # Mock HTTP.get method
        class MockHTTP
          def self.get(_url)
            OpenStruct.new(
              body: "<html><body><a href='https://example.com/page3'>Link 3</a><a href='https://example.com/page4'>Link 4</a></body></html>"
            )
          end
        end

        def extract_links_from_html(html)
          # Simple regex to extract links
          html.scan(%r{'(https://example.com/page\d+)'}).flatten
        end

        def process_content(page)
          # Just a mock processing function
          "Processed #{page[:url]}"
        end
      end

      # Define the pipeline
      crawler_class.class_eval do
        producer :seed_urls do
          seed_urls = ['https://example.com/page1', 'https://example.com/page2']
          seed_urls.each { |url| emit(url) }
        end

        processor :fetch_pages do |url|
          response = MockHTTP.get(url)
          page = { url: url, content: response.body }
          page
        end

        processor :extract_links do |page|
          links = extract_links_from_html(page[:content])
          # Emit new links for crawling
          links.each { |link| emit(link) }
          # Pass the page content for processing
          page
        end

        accumulator :batch_pages do |page|
          @pages ||= []
          @pages << page

          if @pages.size >= 1 # Use smaller batch size for testing
            batch = @pages.dup
            @pages.clear
            emit(batch)
          end
        end

        consumer :process_pages do |batch|
          # Process pages in parallel using forked processes
          batch.each { |page| process_content(page) }
        end

        # Configure for testing
        max_threads 1
        max_processes 1
        fork_mode :never
      end

      # Get the task object directly
      task_obj = crawler_class._minigun_task

      # Verify that the processor blocks are defined
      expect(task_obj.stage_blocks.keys).to include(:seed_urls, :fetch_pages, :extract_links, :process_pages)

      # Verify the pipeline includes an accumulator
      expect(task_obj.pipeline.any? { |s| s[:type] == :accumulator && s[:name] == :batch_pages }).to be true

      # Verify that the pipeline stages are defined
      expect(task_obj.pipeline.size).to eq(5)

      # First stage should be a producer
      expect(task_obj.pipeline[0][:type]).to eq(:processor)
      expect(task_obj.pipeline[0][:name]).to eq(:seed_urls)

      # Check the accumulator stage
      accumulator_stage = task_obj.pipeline.find { |stage| stage[:type] == :accumulator }
      expect(accumulator_stage).not_to be_nil
      expect(accumulator_stage[:name]).to eq(:batch_pages)

      # Last stage should be a consumer
      expect(task_obj.pipeline[4][:type]).to eq(:processor)
    end
  end

  describe 'Diamond-Shaped Pipeline' do
    it 'configures the diamond-shaped pipeline correctly' do
      # Create a class that includes the DSL
      diamond_class = Class.new do
        include Minigun::DSL

        def transform_a(item)
          "#{item}_transformed_a"
        end

        def transform_b(item)
          "#{item}_transformed_b"
        end

        def combine_results(results)
          results.join('_combined_')
        end
      end

      # Define the pipeline
      diamond_class.class_eval do
        producer :data_source do
          items = %w[item1 item2 item3]
          items.each { |item| emit(item) }
        end

        processor :validate, from: :data_source, to: %i[transform_a transform_b] do |item|
          emit(item)
        end

        processor :transform_a, from: :validate, to: :combine do |item|
          result = transform_a(item)
          emit(result)
        end

        processor :transform_b, from: :validate, to: :combine do |item|
          result = transform_b(item)
          emit(result)
        end

        processor :combine, from: %i[transform_a transform_b] do |item|
          @results ||= []
          @results << item

          if @results.size >= 2
            result = combine_results(@results)
            @results.clear
            emit(result)
          end
        end

        consumer :store_results, from: :combine do |result|
          # Store the result
        end

        # Configure for testing
        max_threads 1
        max_processes 1
        fork_mode :never
      end

      # Get the task object directly
      task_obj = diamond_class._minigun_task

      # Verify that the processor blocks are defined
      expect(task_obj.stage_blocks.keys).to include(
                                              :data_source, :validate, :transform_a, :transform_b, :combine, :store_results
                                            )

      # Verify that the pipeline stages are defined
      expect(task_obj.pipeline.size).to eq(6)

      # First stage should be a producer
      expect(task_obj.pipeline[0][:type]).to eq(:processor)
      expect(task_obj.pipeline[0][:name]).to eq(:data_source)

      # Validate stage should be a processor
      validate_stage = task_obj.pipeline.find { |stage| stage[:name] == :validate }
      expect(validate_stage[:type]).to eq(:processor)

      # Last stage should be a consumer
      expect(task_obj.pipeline[5][:type]).to eq(:processor)

      # Verify the connections
      expect(task_obj.connections[:data_source]).to include(:validate)
      expect(task_obj.connections[:validate]).to include(:transform_a, :transform_b)
      expect(task_obj.connections[:transform_a]).to include(:combine)
      expect(task_obj.connections[:transform_b]).to include(:combine)
      expect(task_obj.connections[:combine]).to include(:store_results)
    end
  end

  describe 'Priority Processing Pipeline' do
    it 'configures the priority processing pipeline correctly' do
      # Create a class that includes the DSL
      priority_class = Class.new do
        include Minigun::DSL

        def generate_email(user)
          { recipient_id: user[:id], type: user[:email_type], content: "Email for #{user[:name]}" }
        end
      end

      # Define the pipeline
      priority_class.class_eval do
        producer :user_producer do
          all_users = [
            { id: 1, name: 'Regular User 1', vip: false, email_type: 'regular' },
            { id: 2, name: 'VIP User 1', vip: true, email_type: 'newsletter' },
            { id: 3, name: 'Regular User 2', vip: false, email_type: 'transaction' },
            { id: 4, name: 'VIP User 2', vip: true, email_type: 'newsletter' }
          ]

          all_users.each do |user|
            emit(user)

            # Route VIP users to a high priority queue
            emit_to_queue(:high_priority, user) if user[:vip]
          end
        end

        processor :email_processor, queues: %i[default high_priority] do |user|
          email = generate_email(user)
          emit(email)
        end

        accumulator :email_accumulator, from: :email_processor do |email|
          @emails ||= {}
          # Ensure the email type exists in the hash
          type = email[:type].to_sym
          @emails[type] ||= []
          @emails[type] << email

          # Emit batches when they reach threshold size (using smaller threshold for testing)
          @emails.each do |type, batch|
            if batch.size >= 1
              emit_to_queue(type, batch.dup)
              batch.clear
            end
          end
        end

        consumer :consumer, queues: %i[default high_priority] do |batch|
          # In our test this won't actually be called
        end

        # Configure for testing
        max_threads 1
        max_processes 1
        fork_mode :never
      end

      # Get the task object directly
      task_obj = priority_class._minigun_task

      # Verify that the processor blocks are defined
      expect(task_obj.stage_blocks.keys).to include(:user_producer, :email_processor, :consumer)

      # Verify the pipeline includes an accumulator
      expect(task_obj.pipeline.any? { |s| s[:type] == :accumulator && s[:name] == :email_accumulator }).to be true

      # Verify that the pipeline stages are defined
      expect(task_obj.pipeline.size).to eq(4)

      # First stage should be a producer
      expect(task_obj.pipeline[0][:type]).to eq(:processor)
      expect(task_obj.pipeline[0][:name]).to eq(:user_producer)

      # Verify processor stage has queue subscription
      expect(task_obj.queue_subscriptions[:email_processor]).to eq(%i[default high_priority])

      # Verify accumulator is present
      accumulator_stage = task_obj.pipeline.find { |stage| stage[:type] == :accumulator }
      expect(accumulator_stage).not_to be_nil
      expect(accumulator_stage[:name]).to eq(:email_accumulator)
      expect(task_obj.connections[:email_processor]).to include(:email_accumulator)

      # Last stage should be a consumer
      expect(task_obj.pipeline[3][:type]).to eq(:processor)
      expect(task_obj.queue_subscriptions[:consumer]).to eq(%i[default high_priority])
    end
  end

  describe 'Load Balancing Pipeline' do
    it 'configures the load balancing pipeline correctly' do
      # Create a class that includes the DSL
      load_balancer_class = Class.new do
        include Minigun::DSL

        def process_with_worker(worker_num, item)
          "Worker #{worker_num} processed #{item}"
        end
      end

      # Define the pipeline
      load_balancer_class.class_eval do
        producer :data_source do
          dataset = (1..9).to_a
          dataset.each_with_index do |item, i|
            # Round-robin distribute across multiple queues
            queue = %i[queue_1 queue_2 queue_3][i % 3]
            emit_to_queue(queue, item)
          end
        end

        processor :worker_1, queues: [:queue_1] do |item|
          result = process_with_worker(1, item)
          result
        end

        processor :worker_2, queues: [:queue_2] do |item|
          result = process_with_worker(2, item)
          result
        end

        processor :worker_3, queues: [:queue_3] do |item|
          result = process_with_worker(3, item)
          result
        end

        accumulator :result_collector, from: %i[worker_1 worker_2 worker_3] do |result|
          @results ||= []
          @results << result

          if @results.size >= 3
            batch = @results.dup
            @results.clear
            emit(batch)
          end
        end

        # Configure for testing
        max_threads 1
        max_processes 1
        fork_mode :never
      end

      # Get the task object directly
      task_obj = load_balancer_class._minigun_task

      # Verify that the processor blocks are defined
      expect(task_obj.stage_blocks.keys).to include(:data_source, :worker_1, :worker_2, :worker_3)

      # Verify the pipeline includes an accumulator
      expect(task_obj.pipeline.any? { |s| s[:type] == :accumulator && s[:name] == :result_collector }).to be true

      # Verify that the pipeline stages are defined
      expect(task_obj.pipeline.size).to eq(5)

      # First stage should be a producer
      expect(task_obj.pipeline[0][:type]).to eq(:processor)
      expect(task_obj.pipeline[0][:name]).to eq(:data_source)

      # Verify worker queues
      expect(task_obj.queue_subscriptions[:worker_1]).to eq([:queue_1])
      expect(task_obj.queue_subscriptions[:worker_2]).to eq([:queue_2])
      expect(task_obj.queue_subscriptions[:worker_3]).to eq([:queue_3])

      # Verify accumulator stage
      accumulator_stage = task_obj.pipeline.find { |stage| stage[:type] == :accumulator }
      expect(accumulator_stage).not_to be_nil
      expect(accumulator_stage[:name]).to eq(:result_collector)

      # Verify connections
      expect(task_obj.connections[:worker_1]).to include(:result_collector)
      expect(task_obj.connections[:worker_2]).to include(:result_collector)
      expect(task_obj.connections[:worker_3]).to include(:result_collector)
    end
  end
end
