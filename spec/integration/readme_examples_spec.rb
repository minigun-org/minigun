require 'minigun'
require 'rspec'
require 'ostruct'
require 'set'

RSpec.describe 'README Examples Integration' do
  describe 'Quick Start Example' do
    let(:task_class) do
      Class.new do
        include Minigun::Task
        
        attr_reader :generated_numbers, :transformed_numbers, :batched_items, :processed_batches
        
        def initialize
          @generated_numbers = []
          @transformed_numbers = []
          @batched_items = []
          @processed_batches = []
          @items = []
        end
        
        pipeline do
          producer :generate do
            numbers = (0..9).to_a
            @generated_numbers = numbers.dup
            numbers.each { |i| emit(i) }
          end
          
          processor :transform do |number|
            result = number * 2
            @transformed_numbers << result
            result
          end
          
          accumulator :batch do |item|
            @items ||= []
            @items << item
            
            if @items.size >= 5
              batch = @items.dup
              @batched_items << batch
              @items.clear
              emit(batch)
            end
          end
          
          consumer :process_batch do |batch|
            # Process the batch in a forked child process
            @processed_batches << batch
            batch.each { |item| puts "Processing #{item}" } if ENV['DEBUG']
          end
        end
        
        # Configure for testing
        max_threads 1
        max_processes 1
        fork_mode :never
      end
    end
    
    it 'executes the pipeline stages and blocks per the README' do
      # Create a task instance
      task = task_class.new
      
      # Initialize the pipeline to ensure it's set up correctly
      # This evaluates the pipeline definition without running the task
      pipeline = Minigun::Pipeline.new(task, custom: true)
      pipeline.send(:build_pipeline_from_task_definition)
      
      # Now the pipeline stages should be registered in the class
      expect(task_class._minigun_pipeline.size).to eq(4)
      expect(task_class._minigun_pipeline[0][:type]).to eq(:processor)
      expect(task_class._minigun_pipeline[0][:options][:stage_role]).to eq(:producer)
      expect(task_class._minigun_pipeline[3][:type]).to eq(:processor)
      expect(task_class._minigun_pipeline[3][:options][:stage_role]).to eq(:consumer)
      
      # Test the processor blocks exist
      expect(task_class._minigun_processor_blocks[:generate]).to be_a(Proc)
      expect(task_class._minigun_processor_blocks[:transform]).to be_a(Proc)
      expect(task_class._minigun_processor_blocks[:process_batch]).to be_a(Proc)
      expect(task_class._minigun_accumulator_blocks[:batch]).to be_a(Proc)
      
      # Set up emit method to capture emissions without running the full pipeline
      allow(task).to receive(:emit) { |item| item }
      
      # Evaluate producer block
      producer_block = task_class._minigun_processor_blocks[:generate]
      task.instance_eval(&producer_block) 
      
      # Verify producer output
      expect(task.generated_numbers).to eq([0, 1, 2, 3, 4, 5, 6, 7, 8, 9])
      
      # Process each item through the processor block
      processor_block = task_class._minigun_processor_blocks[:transform]
      task.generated_numbers.each do |item|
        task.instance_exec(item, &processor_block)
      end
      
      # Verify processor output
      expect(task.transformed_numbers).to eq([0, 2, 4, 6, 8, 10, 12, 14, 16, 18])
      
      # Process each item through the accumulator block
      accumulator_block = task_class._minigun_accumulator_blocks[:batch]
      task.transformed_numbers.each do |item|
        task.instance_exec(item, &accumulator_block)
      end
      
      # Verify accumulator batching (should be 2 batches of 5 items)
      expect(task.batched_items.size).to eq(2)
      expect(task.batched_items[0]).to eq([0, 2, 4, 6, 8])
      expect(task.batched_items[1]).to eq([10, 12, 14, 16, 18])
      
      # Process the batches through the consumer block
      consumer_block = task_class._minigun_processor_blocks[:process_batch]
      task.batched_items.each do |batch|
        task.instance_exec(batch, &consumer_block)
      end
      
      # Verify consumer
      expect(task.processed_batches.size).to eq(2)
      expect(task.processed_batches).to match_array(task.batched_items)
    end
  end

  describe 'Data ETL Pipeline' do
    let(:task_class) do
      Class.new do
        include Minigun::Task
        
        attr_reader :extracted_batches, :transformed_batches, :loaded_batches
        
        def initialize
          @extracted_batches = []
          @transformed_batches = []
          @loaded_batches = []
          
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
        
        pipeline do
          producer :extract do
            # Mock database.each_batch
            @database.each_slice(2) do |batch|
              @extracted_batches << batch
              emit(batch)
            end
          end
          
          processor :transform do |batch|
            # Transform the data
            transformed = batch.map { |row| transform_row(row) }
            @transformed_batches << transformed
            transformed
          end
          
          consumer :load do |batch|
            # Load data to destination
            @loaded_batches << batch
          end
        end
        
        # Configure for testing
        max_threads 1
        max_processes 1
        fork_mode :never
      end
    end
    
    it 'executes the ETL pipeline as defined in the README' do
      # Create a task instance
      task = task_class.new
      
      # Initialize the pipeline to ensure it's set up correctly
      pipeline = Minigun::Pipeline.new(task, custom: true)
      pipeline.send(:build_pipeline_from_task_definition)
      
      # Test the pipeline definition
      expect(task_class._minigun_pipeline.size).to eq(3)
      expect(task_class._minigun_pipeline[0][:type]).to eq(:processor)
      expect(task_class._minigun_pipeline[0][:options][:stage_role]).to eq(:producer)
      expect(task_class._minigun_pipeline[2][:type]).to eq(:processor)
      expect(task_class._minigun_pipeline[2][:options][:stage_role]).to eq(:consumer)
      
      # Set up emit method to capture emissions without running the full pipeline
      allow(task).to receive(:emit) { |item| item }
      
      # Run the producer block
      producer_block = task_class._minigun_processor_blocks[:extract]
      task.instance_eval(&producer_block)
      
      # Verify extraction
      expect(task.extracted_batches.size).to eq(3)
      expect(task.extracted_batches.flatten.size).to eq(5)
      
      # Process each batch through the processor block
      processor_block = task_class._minigun_processor_blocks[:transform]
      task.extracted_batches.each do |batch|
        task.instance_exec(batch, &processor_block)
      end
      
      # Verify transformation
      expect(task.transformed_batches.size).to eq(3)
      expect(task.transformed_batches.flatten.size).to eq(5)
      expect(task.transformed_batches.flatten.first[:transformed_name]).to include("Transformed")
      expect(task.transformed_batches.flatten.first[:value]).to eq(20) # doubled from 10
      
      # Process each transformed batch through the consumer block
      consumer_block = task_class._minigun_processor_blocks[:load]
      task.transformed_batches.each do |batch|
        task.instance_exec(batch, &consumer_block)
      end
      
      # Verify loading
      expect(task.loaded_batches).to match_array(task.transformed_batches)
    end
  end

  describe 'Parallel Web Crawler' do
    let(:task_class) do
      Class.new do
        include Minigun::Task
        
        attr_reader :seed_urls, :fetched_pages, :extracted_links, :processed_batches
        
        def initialize
          @seed_urls = [
            "https://example.com/page1",
            "https://example.com/page2"
          ]
          @fetched_pages = []
          @extracted_links = []
          @processed_batches = []
          @pages = []
          @visited_urls = Set.new
        end
        
        # Mock HTTP.get method
        class MockHTTP
          def self.get(url)
            OpenStruct.new(
              body: "<html><body><a href='https://example.com/page3'>Link 3</a><a href='https://example.com/page4'>Link 4</a></body></html>"
            )
          end
        end
        
        def extract_links_from_html(html)
          # Simple regex to extract links
          html.scan(/'(https:\/\/example.com\/page\d+)'/).flatten
        end
        
        def process_content(page)
          # Just a mock processing function
          "Processed #{page[:url]}"
        end
        
        pipeline do
          producer :seed_urls do
            @seed_urls.each { |url| emit(url) }
          end
          
          processor :fetch_pages do |url|
            response = MockHTTP.get(url)
            page = { url: url, content: response.body }
            @fetched_pages << page
            page
          end
          
          processor :extract_links do |page|
            links = extract_links_from_html(page[:content])
            # Track extracted links
            @extracted_links.concat(links)
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
              @processed_batches << batch
              @pages.clear
              emit(batch)
            end
          end
          
          consumer :process_pages do |batch|
            # Process pages in parallel using forked processes
            batch.each { |page| process_content(page) }
          end
        end
        
        # Configure for testing
        max_threads 1
        max_processes 1
        fork_mode :never
      end
    end
    
    it 'executes the web crawler pipeline as defined in the README' do
      # Create a task instance
      task = task_class.new
      
      # Initialize the pipeline to ensure it's set up correctly
      pipeline = Minigun::Pipeline.new(task, custom: true)
      pipeline.send(:build_pipeline_from_task_definition)
      
      # Test the pipeline definition
      expect(task_class._minigun_pipeline.size).to eq(5)
      expect(task_class._minigun_pipeline[0][:type]).to eq(:processor)
      expect(task_class._minigun_pipeline[0][:options][:stage_role]).to eq(:producer)
      expect(task_class._minigun_pipeline[4][:type]).to eq(:processor)
      expect(task_class._minigun_pipeline[4][:options][:stage_role]).to eq(:consumer)
      
      # Define a temporary emit method to collect emitted URLs
      emitted_urls = []
      allow(task).to receive(:emit) do |url|
        emitted_urls << url if url.is_a?(String) && url.include?('example.com')
      end
      
      # Run the producer block
      producer_block = task_class._minigun_processor_blocks[:seed_urls]
      task.instance_eval(&producer_block)
      
      # Verify seed URLs were emitted
      expect(emitted_urls).to match_array(task.seed_urls)
      
      # Process URLs through fetch_pages
      fetch_block = task_class._minigun_processor_blocks[:fetch_pages]
      pages = emitted_urls.map { |url| task.instance_exec(url, &fetch_block) }
      
      # Verify pages were fetched
      expect(task.fetched_pages.size).to eq(2)
      expect(task.fetched_pages.map { |p| p[:url] }).to match_array(task.seed_urls)
      
      # Process pages through extract_links
      extract_block = task_class._minigun_processor_blocks[:extract_links]
      
      # We need to capture new links emitted by extract_links
      new_urls = []
      original_emitted_urls = emitted_urls.dup
      emitted_urls.clear
      
      pages.each do |page|
        task.instance_exec(page, &extract_block)
        new_urls.concat(emitted_urls)
        emitted_urls.clear
      end
      
      # Verify links were extracted
      expect(task.extracted_links.size).to eq(4)
      expect(new_urls.size).to eq(4)
      
      # Process pages through batch_pages
      batch_block = task_class._minigun_accumulator_blocks[:batch_pages]
      
      # Capture emitted batches
      emitted_batches = []
      allow(task).to receive(:emit) do |batch|
        emitted_batches << batch if batch.is_a?(Array)
      end
      
      pages.each do |page|
        task.instance_exec(page, &batch_block)
      end
      
      # Verify batches were created
      expect(task.processed_batches.size).to eq(2)
      
      # Process batches through process_pages
      process_block = task_class._minigun_processor_blocks[:process_pages]
      task.processed_batches.each do |batch|
        task.instance_exec(batch, &process_block)
      end
      
      # Final verification
      expect(task.fetched_pages.size).to eq(2)
      expect(task.extracted_links.size).to eq(4)
      expect(task.processed_batches.size).to eq(2)
    end
  end

  describe 'Diamond-Shaped Pipeline' do
    let(:task_class) do
      Class.new do
        include Minigun::Task
        
        attr_reader :source_items, :validated_items, :transformed_a_items, :transformed_b_items, :combined_results, :stored_results
        
        def initialize
          @source_items = []
          @validated_items = []
          @transformed_a_items = []
          @transformed_b_items = []
          @combined_results = []
          @stored_results = []
        end
        
        def transform_a(item)
          "#{item}_transformed_a"
        end
        
        def transform_b(item)
          "#{item}_transformed_b"
        end
        
        def combine_results(results)
          results.join('_combined_')
        end
        
        pipeline do
          producer :data_source do
            items = ["item1", "item2", "item3"]
            @source_items = items.dup
            items.each { |item| emit(item) }
          end
          
          processor :validate, from: :data_source, to: [:transform_a, :transform_b] do |item|
            @validated_items << item
            emit(item)
          end
          
          processor :transform_a, from: :validate, to: :combine do |item|
            result = transform_a(item)
            @transformed_a_items << result
            emit(result)
          end
          
          processor :transform_b, from: :validate, to: :combine do |item|
            result = transform_b(item)
            @transformed_b_items << result
            emit(result)
          end
          
          processor :combine, from: [:transform_a, :transform_b] do |item|
            @results ||= []
            @results << item
            
            if @results.size >= 2
              result = combine_results(@results)
              @combined_results << result
              @results.clear
              emit(result)
            end
          end
          
          consumer :store_results, from: :combine do |result|
            @stored_results << result
          end
        end
        
        # Configure for testing
        max_threads 1
        max_processes 1
        fork_mode :never
      end
    end
    
    it 'executes the diamond-shaped pipeline as defined in the README' do
      # Create a task instance
      task = task_class.new
      
      # Initialize the pipeline to ensure it's set up correctly
      pipeline = Minigun::Pipeline.new(task, custom: true)
      pipeline.send(:build_pipeline_from_task_definition)
      
      # Test the pipeline definition
      expect(task_class._minigun_pipeline.size).to eq(6)
      expect(task_class._minigun_pipeline[0][:type]).to eq(:processor)
      expect(task_class._minigun_pipeline[0][:options][:stage_role]).to eq(:producer)
      expect(task_class._minigun_pipeline[5][:type]).to eq(:processor)
      expect(task_class._minigun_pipeline[5][:options][:stage_role]).to eq(:consumer)
      
      # Set up emit method to capture emissions
      allow(task).to receive(:emit) { |item| item }
      
      # Run the producer block
      producer_block = task_class._minigun_processor_blocks[:data_source]
      task.instance_eval(&producer_block)
      
      # Verify source items
      expect(task.source_items).to eq(["item1", "item2", "item3"])
      
      # Process items through validate
      validate_block = task_class._minigun_processor_blocks[:validate]
      task.source_items.each do |item|
        task.instance_exec(item, &validate_block)
      end
      
      # Verify validated items
      expect(task.validated_items).to eq(["item1", "item2", "item3"])
      
      # Process items through transform_a
      transform_a_block = task_class._minigun_processor_blocks[:transform_a]
      task.validated_items.each do |item|
        task.instance_exec(item, &transform_a_block)
      end
      
      # Verify transform_a output
      expect(task.transformed_a_items).to eq(["item1_transformed_a", "item2_transformed_a", "item3_transformed_a"])
      
      # Process items through transform_b
      transform_b_block = task_class._minigun_processor_blocks[:transform_b]
      task.validated_items.each do |item|
        task.instance_exec(item, &transform_b_block)
      end
      
      # Verify transform_b output
      expect(task.transformed_b_items).to eq(["item1_transformed_b", "item2_transformed_b", "item3_transformed_b"])
      
      # Process all transformed items through combine (interleave them as they would arrive)
      combine_block = task_class._minigun_processor_blocks[:combine]
      combined_inputs = task.transformed_a_items.zip(task.transformed_b_items).flatten.compact
      combined_inputs.each do |item|
        task.instance_exec(item, &combine_block)
      end
      
      # Verify combined results
      expect(task.combined_results.size).to eq(3)
      
      # Process combined results through store_results
      store_block = task_class._minigun_processor_blocks[:store_results]
      task.combined_results.each do |result|
        task.instance_exec(result, &store_block)
      end
      
      # Verify stored results
      expect(task.stored_results).to match_array(task.combined_results)
    end
  end

  describe 'Priority Processing Pipeline' do
    let(:task_class) do
      Class.new do
        include Minigun::Task
        
        attr_reader :all_users, :vip_users, :regular_users, :generated_emails, :accumulated_emails
        
        def initialize
          @all_users = [
            { id: 1, name: "Regular User 1", vip: false, email_type: "regular" },
            { id: 2, name: "VIP User 1", vip: true, email_type: "newsletter" },
            { id: 3, name: "Regular User 2", vip: false, email_type: "transaction" },
            { id: 4, name: "VIP User 2", vip: true, email_type: "newsletter" }
          ]
          @vip_users = []
          @regular_users = []
          @generated_emails = []
          @accumulated_emails = { newsletter: [], transaction: [], regular: [], default: [] }
        end
        
        def generate_email(user)
          { recipient_id: user[:id], type: user[:email_type], content: "Email for #{user[:name]}" }
        end
        
        pipeline do
          producer :user_producer do
            @all_users.each do |user|
              emit(user)
              
              # Route VIP users to a high priority queue
              if user[:vip]
                @vip_users << user
                emit_to_queue(:high_priority, user)
              else
                @regular_users << user
              end
            end
          end
          
          processor :email_processor, queues: [:default, :high_priority] do |user|
            email = generate_email(user)
            @generated_emails << email
            emit(email)
          end
          
          accumulator :email_accumulator, from: :email_processor do |email|
            @emails ||= @accumulated_emails
            # Ensure the email type exists in the hash
            @emails[email[:type].to_sym] ||= []
            @emails[email[:type].to_sym] << email
            
            # Emit batches when they reach threshold size (using smaller threshold for testing)
            @emails.each do |type, batch|
              if batch.size >= 1
                emit_to_queue(type, batch.dup)
                batch.clear
              end
            end
          end

          consumer :consumer, queues: [:default, :high_priority] do |batch|
            batch.each { |email| puts email }
          end
        end
        
        # Configure for testing
        max_threads 1
        max_processes 1
        fork_mode :never
      end
    end
    
    it 'executes the priority pipeline as defined in the README' do
      # Create a task instance
      task = task_class.new
      
      # Initialize the pipeline to ensure it's set up correctly
      pipeline = Minigun::Pipeline.new(task, custom: true)
      pipeline.send(:build_pipeline_from_task_definition)
      
      # Test the pipeline definition
      expect(task_class._minigun_pipeline.size).to eq(4)
      expect(task_class._minigun_pipeline[0][:type]).to eq(:processor)
      expect(task_class._minigun_pipeline[0][:options][:stage_role]).to eq(:producer)
      expect(task_class._minigun_pipeline[1][:type]).to eq(:processor)
      expect(task_class._minigun_pipeline[1][:options][:stage_role]).to eq(:processor)
      expect(task_class._minigun_pipeline[2][:type]).to eq(:accumulator)
      expect(task_class._minigun_pipeline[3][:type]).to eq(:processor)
      expect(task_class._minigun_pipeline[3][:options][:stage_role]).to eq(:consumer)
      
      # Set up emit method to capture emissions
      emitted_items = []
      allow(task).to receive(:emit) do |item|
        emitted_items << item
        item
      end
      
      # Set up emit_to_queue method to capture queue emissions
      emitted_queue_items = {}
      allow(task).to receive(:emit_to_queue) do |queue, item|
        emitted_queue_items[queue] ||= []
        emitted_queue_items[queue] << item
        item
      end
      
      # Run the producer block
      producer_block = task_class._minigun_processor_blocks[:user_producer]
      task.instance_eval(&producer_block)
      
      # Verify VIP and regular user separation
      expect(task.vip_users.size).to eq(2)
      expect(task.regular_users.size).to eq(2)
      expect(task.vip_users.all? { |u| u[:vip] }).to be_truthy
      expect(task.regular_users.all? { |u| !u[:vip] }).to be_truthy
      
      # The high_priority queue should have VIP users
      expect(emitted_queue_items[:high_priority].size).to eq(2)
      
      # Process all users through the email processor
      processor_block = task_class._minigun_processor_blocks[:email_processor]
      (emitted_items + emitted_queue_items[:high_priority]).each do |user|
        task.instance_exec(user, &processor_block)
      end
      
      # Verify email generation
      expect(task.generated_emails.size).to eq(6) # 4 users in emitted_items + 2 VIP users in high_priority queue
      
      # Clear queue emission tracking for next stage
      emitted_queue_items.clear
      
      # Process emails through the accumulator
      accumulator_block = task_class._minigun_accumulator_blocks[:email_accumulator]
      task.generated_emails.each do |email|
        task.instance_exec(email, &accumulator_block)
      end
      
      # Verify email accumulation
      email_types = task.generated_emails.map { |e| e[:type].to_sym }.uniq
      email_types.each do |type|
        # Check if each type of email was accumulated and batches were emitted
        expect(emitted_queue_items[type]).not_to be_nil
        expect(emitted_queue_items[type].flatten.size).to be > 0
      end
    end
  end

  describe 'Load Balancing Pipeline' do
    let(:task_class) do
      Class.new do
        include Minigun::Task
        
        attr_reader :dataset, :queue_assignments, :processed_items, :collected_results
        
        def initialize
          @dataset = (1..9).to_a
          @queue_assignments = {}
          @processed_items = { queue_1: [], queue_2: [], queue_3: [] }
          @collected_results = []
        end
        
        def process_with_worker(worker_num, item)
          "Worker #{worker_num} processed #{item}"
        end
        
        pipeline do
          producer :data_source do
            @dataset.each_with_index do |item, i|
              # Round-robin distribute across multiple queues
              queue = [:queue_1, :queue_2, :queue_3][i % 3]
              @queue_assignments[item] = queue
              emit_to_queue(queue, item)
            end
          end
          
          processor :worker_1, queues: [:queue_1] do |item|
            result = process_with_worker(1, item)
            @processed_items[:queue_1] << result
            result
          end
          
          processor :worker_2, queues: [:queue_2] do |item|
            result = process_with_worker(2, item)
            @processed_items[:queue_2] << result
            result
          end
          
          processor :worker_3, queues: [:queue_3] do |item|
            result = process_with_worker(3, item)
            @processed_items[:queue_3] << result
            result
          end
          
          accumulator :result_collector, from: [:worker_1, :worker_2, :worker_3] do |result|
            @results ||= []
            @results << result
            @collected_results << result
            
            if @results.size >= 3
              batch = @results.dup
              @results.clear
              emit(batch)
            end
          end
        end
        
        # Configure for testing
        max_threads 1
        max_processes 1
        fork_mode :never
      end
    end
    
    it 'executes the load balancing pipeline as defined in the README' do
      # Create a task instance
      task = task_class.new
      
      # Initialize the pipeline to ensure it's set up correctly
      pipeline = Minigun::Pipeline.new(task, custom: true)
      pipeline.send(:build_pipeline_from_task_definition)
      
      # Test the pipeline definition
      expect(task_class._minigun_pipeline.size).to eq(5)
      
      # Set up emit method to capture emissions
      allow(task).to receive(:emit) { |item| item }
      
      # Set up emit_to_queue method to capture queue emissions
      queue_items = { queue_1: [], queue_2: [], queue_3: [] }
      allow(task).to receive(:emit_to_queue) do |queue, item|
        queue_items[queue] << item
        item
      end
      
      # Run the producer block
      producer_block = task_class._minigun_processor_blocks[:data_source]
      task.instance_eval(&producer_block)
      
      # Verify queue distribution
      expect(queue_items[:queue_1].size).to eq(3)
      expect(queue_items[:queue_2].size).to eq(3)
      expect(queue_items[:queue_3].size).to eq(3)
      expect(task.queue_assignments.values.uniq.sort).to eq([:queue_1, :queue_2, :queue_3])
      
      # Process items through respective workers
      worker1_block = task_class._minigun_processor_blocks[:worker_1]
      worker2_block = task_class._minigun_processor_blocks[:worker_2]
      worker3_block = task_class._minigun_processor_blocks[:worker_3]
      
      queue_items[:queue_1].each { |item| task.instance_exec(item, &worker1_block) }
      queue_items[:queue_2].each { |item| task.instance_exec(item, &worker2_block) }
      queue_items[:queue_3].each { |item| task.instance_exec(item, &worker3_block) }
      
      # Verify worker processing
      expect(task.processed_items[:queue_1].size).to eq(3)
      expect(task.processed_items[:queue_2].size).to eq(3)
      expect(task.processed_items[:queue_3].size).to eq(3)
      expect(task.processed_items[:queue_1].all? { |r| r.include?("Worker 1") }).to be_truthy
      expect(task.processed_items[:queue_2].all? { |r| r.include?("Worker 2") }).to be_truthy
      expect(task.processed_items[:queue_3].all? { |r| r.include?("Worker 3") }).to be_truthy
      
      # Set up emit to capture batches
      emitted_batches = []
      allow(task).to receive(:emit) do |batch|
        emitted_batches << batch if batch.is_a?(Array)
        batch
      end
      
      # Process all results through the collector
      accumulator_block = task_class._minigun_accumulator_blocks[:result_collector]
      all_processed = task.processed_items.values.flatten
      all_processed.each { |result| task.instance_exec(result, &accumulator_block) }
      
      # Verify result collection
      expect(task.collected_results.size).to eq(9)
      expect(emitted_batches.size).to eq(3)
      expect(emitted_batches.flatten.size).to eq(9)
    end
  end
end 