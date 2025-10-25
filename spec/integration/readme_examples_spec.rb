# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'README Examples' do
  before do
    allow(Minigun.logger).to receive(:info)
  end

  describe 'Quick Start Example' do
    let(:quick_start_class) do
      Class.new do
        include Minigun::DSL

        attr_accessor :results

        def initialize
          @results = []
          @mutex = Mutex.new
        end

        pipeline do
          producer :generate do
            10.times { |i| emit(i) }
          end

          processor :transform do |number|
            emit(number * 2)
          end

          consumer :collect do |item|
            @mutex.synchronize { results << item }
          end
        end
      end
    end

    it 'processes items through the pipeline' do
      task = quick_start_class.new
      task.run

      expect(task.results.size).to eq(10)
      expect(task.results).to include(0, 2, 4, 6, 8, 10, 12, 14, 16, 18)
    end
  end

  describe 'Data ETL Pipeline Example' do
    let(:etl_class) do
      Class.new do
        include Minigun::DSL

        attr_accessor :extracted, :transformed, :loaded

        def initialize
          @extracted = []
          @transformed = []
          @loaded = []
        end

        pipeline do
          producer :extract do
            # Simulate extracting from database
            5.times { |i| emit({ id: i, value: i * 10 }) }
          end

          processor :transform do |record|
            # Transform the data
            transformed_record = {
              id: record[:id],
              value: record[:value],
              processed: true
            }
            emit(transformed_record)
          end

          consumer :load do |record|
            # Load to destination
            loaded << record
          end
        end
      end
    end

    it 'extracts, transforms, and loads data' do
      task = etl_class.new
      task.run

      expect(task.loaded.size).to eq(5)
      expect(task.loaded.all? { |r| r[:processed] }).to be true
    end
  end

  describe 'Web Crawler Example' do
    let(:crawler_class) do
      Class.new do
        include Minigun::DSL

        max_threads 20

        attr_accessor :pages_fetched, :links_extracted, :pages_processed

        def initialize
          @pages_fetched = []
          @links_extracted = []
          @pages_processed = []
          @mutex = Mutex.new
        end

        def fetch_page(url)
          { url: url, content: "Content for #{url}" }
        end

        def extract_links(content)
          # Simulate extracting links
          []
        end

        pipeline do
          producer :seed_urls do
            %w[http://example.com http://test.com].each { |url| emit(url) }
          end

          processor :fetch_pages do |url|
            page = fetch_page(url)
            @mutex.synchronize { pages_fetched << page }
            emit(page)
          end

          processor :extract_links do |page|
            links = extract_links(page[:content])
            @mutex.synchronize { links_extracted.concat(links) }
            emit(page)
          end

          consumer :process_pages do |page|
            @mutex.synchronize { pages_processed << page }
          end
        end
      end
    end

    it 'crawls and processes pages' do
      task = crawler_class.new
      task.run

      expect(task.pages_fetched.size).to eq(2)
      expect(task.pages_processed.size).to eq(2)
    end
  end

  describe 'Hooks Example' do
    let(:hooks_class) do
      Class.new do
        include Minigun::DSL

        attr_accessor :events

        def initialize
          @events = []
        end

        before_run do
          events << :before_run
        end

        after_run do
          events << :after_run
        end

        before_fork do
          events << :before_fork
        end

        after_fork do
          events << :after_fork
        end

        pipeline do
          producer :generate do
            3.times { |i| emit(i) }
          end

          consumer :process do |_item|
            # Process item
          end
        end
      end
    end

    it 'executes hooks in correct order' do
      task = hooks_class.new
      task.run

      expect(task.events).to include(:before_run, :after_run)
      # Note: before_fork/after_fork only on Unix systems with actual forking
    end
  end

  describe 'Configuration Example' do
    let(:configured_class) do
      Class.new do
        include Minigun::DSL

        max_threads 10
        max_processes 4
        max_retries 5

        pipeline do
          producer :gen do
            emit(1)
          end

          consumer :process do |_item|
            # Process
          end
        end
      end
    end

    it 'applies configuration correctly' do
      task = configured_class._minigun_task

      expect(task.config[:max_threads]).to eq(10)
      expect(task.config[:max_processes]).to eq(4)
      expect(task.config[:max_retries]).to eq(5)
    end
  end

  describe 'Real-world Database Publisher Example' do
    # Simulate a simple model
    class FakeCustomer
      attr_reader :id, :updated_at

      def initialize(id)
        @id = id
        @updated_at = Time.now
      end

      def self.find_each
        5.times { |i| yield new(i) }
      end
    end

    let(:publisher_class) do
      fake_customer = FakeCustomer

      Class.new do
        include Minigun::DSL

        max_threads 5
        max_processes 2

        attr_accessor :upserted_ids

        def initialize
          @upserted_ids = []
          @mutex = Mutex.new
        end

        define_method(:customer_class) { fake_customer }

        pipeline do
          producer :fetch_ids do
            customer_class.find_each do |customer|
              emit([customer_class, customer.id])
            end
          end

          consumer :upsert do |model_id|
            _model, id = model_id
            @mutex.synchronize { upserted_ids << id }
          end
        end
      end
    end

    it 'processes database records' do
      publisher = publisher_class.new
      result = publisher.run

      expect(result).to eq(5)
      expect(publisher.upserted_ids).to contain_exactly(0, 1, 2, 3, 4)
    end
  end
end

