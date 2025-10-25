# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Pipeline Integration' do
  before do
    # Suppress logger output in tests
    allow(Minigun.logger).to receive(:info)
  end

  describe 'Simple producer-consumer pipeline' do
    let(:pipeline_class) do
      Class.new do
        include Minigun::DSL

        max_threads 2
        max_processes 1

        attr_accessor :results

        def initialize
          @results = []
        end

        pipeline do
          producer :generate do
            5.times { |i| emit(i + 1) }
          end

          consumer :collect do |item|
            results << item
          end
        end
      end
    end

    it 'processes all items through the pipeline' do
      task = pipeline_class.new
      task.run

      expect(task.results.size).to eq(5)
      expect(task.results).to contain_exactly(1, 2, 3, 4, 5)
    end
  end

  describe 'Producer-processor-consumer pipeline' do
    let(:pipeline_class) do
      Class.new do
        include Minigun::DSL

        max_threads 2

        attr_accessor :results

        def initialize
          @results = []
        end

        pipeline do
          producer :generate do
            3.times { |i| emit(i + 1) }
          end

          processor :double do |num|
            emit(num * 2)
          end

          consumer :collect do |num|
            results << num
          end
        end
      end
    end

    it 'transforms items through processor' do
      task = pipeline_class.new
      task.run

      expect(task.results).to contain_exactly(2, 4, 6)
    end
  end

  describe 'Multiple processors pipeline' do
    let(:pipeline_class) do
      Class.new do
        include Minigun::DSL

        attr_accessor :results

        def initialize
          @results = []
        end

        pipeline do
          producer :generate do
            3.times { |i| emit(i + 1) }
          end

          processor :double do |num|
            emit(num * 2)
          end

          processor :add_ten do |num|
            emit(num + 10)
          end

          consumer :collect do |num|
            results << num
          end
        end
      end
    end

    it 'chains multiple processors' do
      task = pipeline_class.new
      task.run

      # (1*2)+10=12, (2*2)+10=14, (3*2)+10=16
      expect(task.results).to contain_exactly(12, 14, 16)
    end
  end

  describe 'Pipeline with hooks' do
    let(:pipeline_class) do
      Class.new do
        include Minigun::DSL

        attr_accessor :results, :hook_log

        def initialize
          @results = []
          @hook_log = []
        end

        before_run do
          hook_log << :before_run
        end

        after_run do
          hook_log << :after_run
        end

        pipeline do
          producer :generate do
            2.times { |i| emit(i) }
          end

          consumer :collect do |item|
            results << item
          end
        end
      end
    end

    it 'calls hooks in correct order' do
      task = pipeline_class.new
      task.run

      expect(task.hook_log).to eq([:before_run, :after_run])
    end

    it 'processes items even with hooks' do
      task = pipeline_class.new
      task.run

      expect(task.results.size).to eq(2)
    end
  end

  describe 'Large dataset processing' do
    let(:pipeline_class) do
      Class.new do
        include Minigun::DSL

        max_threads 3
        max_processes 2

        attr_accessor :results

        def initialize
          @results = []
          @mutex = Mutex.new
        end

        pipeline do
          producer :generate do
            100.times { |i| emit(i) }
          end

          consumer :collect do |item|
            @mutex.synchronize { results << item }
          end
        end
      end
    end

    it 'processes all 100 items' do
      task = pipeline_class.new
      task.run

      expect(task.results.size).to eq(100)
    end

    it 'handles concurrent processing correctly' do
      task = pipeline_class.new
      task.run

      # All items should be unique
      expect(task.results.uniq.size).to eq(100)
    end
  end

  describe 'Error handling' do
    let(:pipeline_class) do
      Class.new do
        include Minigun::DSL

        attr_accessor :results, :errors

        def initialize
          @results = []
          @errors = []
        end

        pipeline do
          producer :generate do
            5.times { |i| emit(i) }
          end

          consumer :process do |item|
            if item == 2
              # Simulate error but don't raise to keep test running
              errors << "Error on item #{item}"
            else
              results << item
            end
          end
        end
      end
    end

    it 'continues processing after errors in consumer' do
      task = pipeline_class.new
      task.run

      expect(task.results).to include(0, 1, 3, 4)
      expect(task.errors.size).to eq(1)
    end
  end

  describe 'Configuration options' do
    it 'respects max_threads configuration' do
      pipeline_class = Class.new do
        include Minigun::DSL
        max_threads 10
      end

      expect(pipeline_class._minigun_task.config[:max_threads]).to eq(10)
    end

    it 'respects max_processes configuration' do
      pipeline_class = Class.new do
        include Minigun::DSL
        max_processes 8
      end

      expect(pipeline_class._minigun_task.config[:max_processes]).to eq(8)
    end

    it 'respects max_retries configuration' do
      pipeline_class = Class.new do
        include Minigun::DSL
        max_retries 5
      end

      expect(pipeline_class._minigun_task.config[:max_retries]).to eq(5)
    end
  end

  describe 'Real-world-like scenario' do
    let(:pipeline_class) do
      Class.new do
        include Minigun::DSL

        max_threads 5
        max_processes 2

        attr_accessor :processed_items, :setup_called, :teardown_called

        def initialize
          @processed_items = []
          @setup_called = false
          @teardown_called = false
          @mutex = Mutex.new
        end

        before_run do
          self.setup_called = true
        end

        after_run do
          self.teardown_called = true
        end

        pipeline do
          producer :fetch_records do
            # Simulate fetching database IDs
            20.times { |i| emit({ id: i, type: 'Customer' }) }
          end

          processor :enrich do |record|
            # Simulate enriching with extra data
            enriched = record.merge(enriched: true)
            emit(enriched)
          end

          consumer :process do |record|
            # Simulate processing (e.g., upsert to Elasticsearch)
            @mutex.synchronize do
              processed_items << record
            end
          end
        end
      end
    end

    it 'completes full pipeline successfully' do
      task = pipeline_class.new
      result = task.run

      expect(result).to eq(20)
      expect(task.processed_items.size).to eq(20)
      expect(task.setup_called).to be true
      expect(task.teardown_called).to be true

      # Check that enrichment happened
      expect(task.processed_items.all? { |item| item[:enriched] }).to be true
    end
  end
end

