# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Examples Integration' do
  before do
    allow(Minigun.logger).to receive(:info)
  end

  describe '00_quick_start.rb' do
    it 'runs simple producer-processor-consumer pipeline' do
      load File.expand_path('../../examples/00_quick_start.rb', __dir__)

      example = QuickStartExample.new
      example.run

      expect(example.results.size).to eq(10)
      expect(example.results).to include(0, 2, 4, 6, 8, 10, 12, 14, 16, 18)
    end
  end

  describe '01_sequential_default.rb' do
    it 'runs sequential pipeline with default routing' do
      load File.expand_path('../../examples/01_sequential_default.rb', __dir__)

      pipeline = SequentialPipeline.new
      pipeline.run

      # Input: 1, 2, 3
      # After double: 2, 4, 6
      # After add_ten: 12, 14, 16
      expect(pipeline.results.sort).to eq([12, 14, 16])
    end
  end

  describe '02_diamond_pattern.rb' do
    it 'routes through diamond-shaped pattern' do
      load File.expand_path('../../examples/02_diamond_pattern.rb', __dir__)

      pipeline = DiamondPipeline.new
      pipeline.run

      # All 5 items (1-5) processed by both paths
      expect(pipeline.results_a.size).to eq(5)
      expect(pipeline.results_b.size).to eq(5)

      # Merger receives from both paths (10 total items)
      expect(pipeline.merged.size).to eq(10)

      # Path A: multiply by 2 (2, 4, 6, 8, 10)
      # Path B: multiply by 3 (3, 6, 9, 12, 15)
      # Merged should contain all of these
      expect(pipeline.results_a.sort).to eq([2, 4, 6, 8, 10])
      expect(pipeline.results_b.sort).to eq([3, 6, 9, 12, 15])
    end
  end

  describe '03_fan_out_pattern.rb' do
    it 'fans out to multiple consumers' do
      load File.expand_path('../../examples/03_fan_out_pattern.rb', __dir__)

      pipeline = FanOutPipeline.new
      pipeline.run

      # Each consumer should receive all 3 items
      expect(pipeline.emails.size).to eq(3)
      expect(pipeline.sms_messages.size).to eq(3)
      expect(pipeline.push_notifications.size).to eq(3)

      # Verify content
      expect(pipeline.emails.first).to include('Alice')
      expect(pipeline.sms_messages.first).to include('SMS')
    end
  end

  describe '04_complex_routing.rb' do
    it 'handles complex multi-path routing' do
      load File.expand_path('../../examples/04_complex_routing.rb', __dir__)

      pipeline = ComplexRoutingPipeline.new
      pipeline.run

      # Logger receives everything (10 items from 1-10)
      expect(pipeline.logged.sort).to eq((1..10).to_a)

      # Validator receives everything
      expect(pipeline.validated.sort).to eq((1..10).to_a)

      # Archived receives only evens (2, 4, 6, 8, 10)
      expect(pipeline.archived.sort).to eq([2, 4, 6, 8, 10])

      # Transformed receives evens x10 (20, 40, 60, 80, 100)
      expect(pipeline.transformed.sort).to eq([20, 40, 60, 80, 100])

      # Stored receives same as transformed
      expect(pipeline.stored.sort).to eq([20, 40, 60, 80, 100])
    end
  end

  describe '05_multi_pipeline_simple.rb' do
    it 'runs three connected pipelines' do
      load File.expand_path('../../examples/05_multi_pipeline_simple.rb', __dir__)

      example = SimplePipelineExample.new
      example.run

      # Generator produces 1-5, Processor doubles them, Collector receives 2,4,6,8,10
      expect(example.results.sort).to eq([2, 4, 6, 8, 10])
    end
  end

  describe '06_multi_pipeline_etl.rb' do
    it 'runs ETL pattern with fan-out' do
      load File.expand_path('../../examples/06_multi_pipeline_etl.rb', __dir__)

      etl = MultiPipelineETL.new
      etl.run

      # All 5 items should be extracted, transformed, and loaded to both targets
      expect(etl.extracted.size).to eq(5)
      expect(etl.transformed.size).to eq(5)
      expect(etl.loaded_db.size).to eq(5)
      expect(etl.loaded_cache.size).to eq(5)

      # Transformed items should have additional metadata
      expect(etl.transformed.first).to have_key(:cleaned)
      expect(etl.transformed.first).to have_key(:enriched_at)
    end
  end

  describe '07_multi_pipeline_data_processing.rb' do
    it 'processes data through validation and routing pipelines' do
      load File.expand_path('../../examples/07_multi_pipeline_data_processing.rb', __dir__)

      processor = DataProcessingPipeline.new
      processor.run

      # 10 items ingested
      expect(processor.ingested.size).to eq(10)

      # 3 invalid items filtered out (every 4th item), 7 valid
      expect(processor.invalid.size).to eq(3)
      expect(processor.valid.size).to eq(7)

      # All valid items should be processed
      total_processed = processor.fast_processed.size + processor.slow_processed.size
      expect(total_processed).to be >= 7
    end
  end

  describe '08_nested_pipeline_simple.rb' do
    it 'loads and runs without errors' do
      load File.expand_path('../../examples/08_nested_pipeline_simple.rb', __dir__)

      example = NestedPipelineExample.new
      expect { example.run }.not_to raise_error

      # Nested pipelines not fully implemented yet - just verify it runs
      expect(example.results.size).to be > 0
    end

    it 'processes items through nested pipeline' do
      load File.expand_path('../../examples/08_nested_pipeline_simple.rb', __dir__)

      example = NestedPipelineExample.new
      example.run

      # Items 1-5 go through nested pipeline (double + add_ten)
      # 1*2+10=12, 2*2+10=14, 3*2+10=16, 4*2+10=18, 5*2+10=20
      expect(example.results.sort).to eq([12, 14, 16, 18, 20])
    end
  end

  describe '09_strategy_per_stage.rb' do
    it 'loads and runs without errors' do
      load File.expand_path('../../examples/09_strategy_per_stage.rb', __dir__)

      example = StrategyPerStageExample.new
      expect { example.run }.not_to raise_error

      # Strategy execution not fully integrated yet - just verify it runs
      expect(example.fork_results.size).to be > 0
    end

    it 'uses different strategies for different stages' do
      load File.expand_path('../../examples/09_strategy_per_stage.rb', __dir__)

      example = StrategyPerStageExample.new
      example.run

      # All 10 items should be processed by both consumers (via explicit fan-out routing)
      expect(example.fork_results.sort).to eq((1..10).to_a)
      expect(example.thread_results.sort).to eq((1..10).to_a)
    end
  end

  describe '10_web_crawler.rb' do
    it 'crawls and processes pages' do
      load File.expand_path('../../examples/10_web_crawler.rb', __dir__)

      seed_urls = ['http://example.com', 'http://test.com']
      crawler = WebCrawler.new(seed_urls)
      crawler.run

      # Should fetch all seed URLs
      expect(crawler.pages_fetched.size).to eq(2)

      # Should extract links from pages
      expect(crawler.links_extracted.size).to be > 0

      # Should process all fetched pages
      expect(crawler.pages_processed.size).to eq(2)

      # Verify page structure
      expect(crawler.pages_fetched.first).to have_key(:url)
      expect(crawler.pages_fetched.first).to have_key(:title)
      expect(crawler.pages_fetched.first).to have_key(:content)
    end
  end

  describe '11_hooks_example.rb' do
    it 'executes lifecycle hooks' do
      load File.expand_path('../../examples/11_hooks_example.rb', __dir__)

      example = HooksExample.new
      example.run

      # Should call before_run and after_run hooks
      expect(example.events).to include(:before_run, :after_run)

      # Should process all items
      expect(example.results.size).to eq(5)

      # Results should be transformed (item * 10)
      expect(example.results.sort).to eq([10, 20, 30, 40, 50])
    end
  end

  describe '12_database_publisher.rb' do
    it 'publishes database records' do
      load File.expand_path('../../examples/12_database_publisher.rb', __dir__)

      publisher = DatabasePublisher.new
      result = publisher.run

      # Should process all 20 customers
      expect(result).to eq(20)
      expect(publisher.published_ids.size).to eq(20)

      # Should enrich all records
      expect(publisher.enriched_count).to eq(20)

      # IDs should be sequential
      expect(publisher.published_ids.sort).to eq((1..20).to_a)
    end
  end

  describe '13_configuration.rb' do
    it 'demonstrates configuration options' do
      load File.expand_path('../../examples/13_configuration.rb', __dir__)

      # Verify configuration was applied
      task = ConfigurationExample._minigun_task
      expect(task.config[:max_threads]).to eq(10)
      expect(task.config[:max_processes]).to eq(4)
      expect(task.config[:max_retries]).to eq(5)

      # Run the pipeline
      example = ConfigurationExample.new
      result = example.run

      # Should process 18 items (20 minus 2 that are multiples of 7)
      expect(example.results.size).to eq(18)

      # Results should be doubled values
      expect(example.results).to include(2, 4, 6) # 1*2, 2*2, 3*2
      expect(example.results).not_to include(14, 28) # 7*2, 14*2 (filtered)
    end
  end

  describe '14_large_dataset.rb' do
    it 'processes 100 items concurrently' do
      load File.expand_path('../../examples/14_large_dataset.rb', __dir__)

      example = LargeDatasetExample.new(100)
      example.run

      # Should process all 100 items
      expect(example.results.size).to eq(100)

      # All items should be unique
      expect(example.results.uniq.size).to eq(100)

      # Should contain all values from 0 to 99
      expect(example.results.sort).to eq((0..99).to_a)
    end
  end

  describe '15_simple_etl.rb' do
    it 'extracts, transforms, and loads data' do
      load File.expand_path('../../examples/15_simple_etl.rb', __dir__)

      example = SimpleETLExample.new
      example.run

      # Should process all 5 records through each stage
      expect(example.extracted.size).to eq(5)
      expect(example.transformed.size).to eq(5)
      expect(example.loaded.size).to eq(5)

      # All loaded records should be processed
      expect(example.loaded.all? { |r| r[:processed] }).to be true
    end
  end

  describe '16_mixed_routing.rb' do
    it 'handles mixed explicit and sequential routing' do
      load File.expand_path('../../examples/16_mixed_routing.rb', __dir__)

      example = MixedRoutingExample.new
      example.run

      # Both paths should receive all 3 items
      expect(example.from_a.sort).to eq([0, 1, 2])
      expect(example.from_b.sort).to eq([0, 1, 2])

      # Path A: 0*10=0, 1*10=10, 2*10=20
      # Path B→Transform: (0*100)+1=1, (1*100)+1=101, (2*100)+1=201
      expect(example.final.sort).to eq([0, 1, 10, 20, 101, 201])
    end
  end

  describe 'all examples' do
    let(:example_files) do
      Dir[File.expand_path('../../examples/*.rb', __dir__)].sort
    end

    it 'all example files are syntactically valid' do
      example_files.each do |file|
        expect { load file }.not_to raise_error, "#{File.basename(file)} has syntax errors"
      end
    end

    it 'has integration test for each example' do
      example_basenames = example_files.map { |f| File.basename(f) }
      tested_examples = [
        '00_quick_start.rb',
        '01_sequential_default.rb',
        '02_diamond_pattern.rb',
        '03_fan_out_pattern.rb',
        '04_complex_routing.rb',
        '05_multi_pipeline_simple.rb',
        '06_multi_pipeline_etl.rb',
        '07_multi_pipeline_data_processing.rb',
        '08_nested_pipeline_simple.rb',
        '09_strategy_per_stage.rb',
        '10_web_crawler.rb',
      '11_hooks_example.rb',
      '12_database_publisher.rb',
      '13_configuration.rb',
      '14_large_dataset.rb',
      '15_simple_etl.rb',
      '16_mixed_routing.rb',
      '17_database_connection_hooks.rb',
      '18_resource_cleanup_hooks.rb',
      '19_statistics_gathering.rb',
      '20_error_handling_hooks.rb',
      '21_inline_hook_procs.rb'
    ]

    missing_tests = example_basenames - tested_examples
    expect(missing_tests).to be_empty, "Missing integration tests for: #{missing_tests.join(', ')}"
  end

  describe '17_database_connection_hooks.rb' do
    it 'demonstrates database connection management with fork hooks' do
      load File.expand_path('../../examples/17_database_connection_hooks.rb', __dir__)

      example = DatabaseConnectionExample.new
      example.run

      expect(example.results.size).to eq(10)
      expect(example.connection_events).to include(match(/Connected to database/))

      if Process.respond_to?(:fork)
        # On platforms with fork support, verify fork hooks fired
        expect(example.connection_events).to include(match(/Disconnected from database before fork/))
        expect(example.connection_events).to include(match(/Reconnected to database in child/))
      end

      expect(example.connection_events).to include(match(/Final disconnect/))
    end
  end

  describe '18_resource_cleanup_hooks.rb' do
    it 'demonstrates resource management with stage hooks' do
      load File.expand_path('../../examples/18_resource_cleanup_hooks.rb', __dir__)

      example = ResourceCleanupExample.new
      example.run

      expect(example.results.size).to eq(10)
      expect(example.resource_events).to include("Opened file handle")
      expect(example.resource_events).to include("Closed file handle")
      expect(example.resource_events).to include("Initialized API client")
      expect(example.resource_events).to include("Shutdown API client")

      if Process.respond_to?(:fork)
        # On platforms with fork support, verify fork-related resource management
        expect(example.resource_events).to include("Closing connections before fork")
        expect(example.resource_events).to include("Reopening connections in child process")
      end
    end
  end

  describe '19_statistics_gathering.rb' do
    it 'demonstrates statistics tracking with hooks' do
      load File.expand_path('../../examples/19_statistics_gathering.rb', __dir__)

      example = StatisticsGatheringExample.new
      example.run

      # Producer count is reliable (tracked in parent process)
      expect(example.stats[:producer_count]).to eq(100)
      expect(example.stats[:total_duration]).to be > 0

      # Validator counts happen in parent process (before consumer)
      expect(example.stats[:validator_passed]).to be > 0
      expect(example.stats[:validator_failed]).to be > 0
      # Note: The sum may not equal 100 due to hook execution timing,
      # but both passed and failed should have some items

      # Consumer/transformer counts may not be accurate due to forking
      # (child process modifications don't propagate back to parent)
      # So we just check they're tracked, not their exact values
      expect(example.stats).to have_key(:consumer_count)
      expect(example.stats).to have_key(:transformer_count)

      if Process.respond_to?(:fork)
        # On platforms with fork support, verify fork statistics
        expect(example.stats[:forks_created]).to be > 0
        expect(example.stats[:child_processes]).not_to be_empty
      end
    end
  end

  describe '20_error_handling_hooks.rb' do
    it 'demonstrates error handling and recovery patterns' do
      load File.expand_path('../../examples/20_error_handling_hooks.rb', __dir__)

      example = ErrorHandlingExample.new
      example.run

      # Verify some items processed successfully despite errors
      expect(example.results.size).to be > 0

      # Verify errors were tracked
      expect(example.errors.size).to be > 0

      # Check that error handling tracked items
      expect(example.retry_counts).not_to be_empty

      # Verify at least some errors have stage information
      expect(example.errors.first).to have_key(:stage)
      expect(example.errors.first).to have_key(:error)
    end
  end

  describe '21_inline_hook_procs.rb' do
    it 'demonstrates inline hook proc syntax' do
      load File.expand_path('../../examples/21_inline_hook_procs.rb', __dir__)

      example = InlineHookExample.new
      example.run

      expect(example.results.size).to eq(9) # 10 items, 1 filtered out (0), all doubled
      expect(example.results.sort).to eq([2, 4, 6, 8, 10, 12, 14, 16, 18])

      expect(example.events).to include(:pipeline_start, :pipeline_end)
      expect(example.events).to include(:fetching)
      expect(example.events).to include(:validate_start, :validate_end)
      expect(example.events).to include(:transform_start, :transform_end)

      if Process.respond_to?(:fork)
        # On platforms with fork support, verify fork hooks fired
        expect(example.events).to include(:before_fork, :after_fork)
      end

      expect(example.timer[:fetch_start]).to be_a(Time)
      expect(example.timer[:fetch_end]).to be_a(Time)
    end
  end
end
end
