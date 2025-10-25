#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

# Pipeline A: Generates main workflow items
class MainWorkflowPipeline
  include Minigun::DSL

  attr_accessor :results

  def initialize
    @results = []
    @mutex = Mutex.new
  end

  # Single producer - main workflow generator
  producer :generate_workflows do
    puts "[Main Pipeline] Generating workflows..."
    5.times do |i|
      emit({ type: 'workflow', id: i, priority: i % 2 == 0 ? 'high' : 'normal' })
    end
    puts "[Main Pipeline] Generated 5 workflows"
  end

  processor :validate do |item|
    item[:validated] = true
    emit(item)
  end

  consumer :forward do |item|
    @mutex.synchronize do
      @results << item
      puts "[Main] Forwarding: workflow #{item[:id]} (#{item[:priority]})"
    end
  end
end

# Pipeline B: Processes items from Pipeline A + has its own producers
class EnrichmentPipeline
  include Minigun::DSL

  attr_accessor :results

  def initialize
    @results = []
    @mutex = Mutex.new
  end

  # Producer 1: Reference data from cache
  producer :cache_reference do
    puts "[Enrichment] Loading reference data from cache..."
    3.times do |i|
      emit({ type: 'reference', source: 'cache', id: i + 100, data: "Cache ref #{i}" })
    end
    puts "[Enrichment] Loaded 3 cache references"
  end

  # Producer 2: Configuration from config service
  producer :config_data do
    puts "[Enrichment] Fetching configuration..."
    2.times do |i|
      emit({ type: 'config', source: 'config_service', id: i + 200, setting: "Setting #{i}" })
    end
    puts "[Enrichment] Fetched 2 configs"
  end

  # Note: This pipeline ALSO receives items from MainWorkflowPipeline
  # Those items come through the input_queue automatically

  # Processor enriches all items (from upstream + local producers)
  processor :enrich do |item|
    enriched = item.merge(
      enriched_at: Time.now.to_i,
      pipeline: 'enrichment'
    )
    emit(enriched)
  end

  # Processor for routing
  processor :route do |item|
    case item[:type]
    when 'workflow'
      puts "[Route] Workflow item: #{item[:id]}"
    when 'reference'
      puts "[Route] Reference data: #{item[:source]}"
    when 'config'
      puts "[Route] Config: #{item[:setting]}"
    end
    emit(item)
  end

  consumer :store do |item|
    @mutex.synchronize do
      @results << item
      puts "[Store] Stored: #{item[:type]} from #{item[:source] || 'upstream'}"
    end
  end
end

if __FILE__ == $0
  puts "=== Multi-Pipeline with Multiple Producers Example ==="
  puts "Pipeline A (main workflow) → Pipeline B (enrichment with 2 additional producers)\n\n"

  # Create both pipelines
  main_pipeline = MainWorkflowPipeline.new
  enrichment_pipeline = EnrichmentPipeline.new

  # Get the task instances
  main_task = main_pipeline.class._minigun_task
  enrichment_task = enrichment_pipeline.class._minigun_task

  # Connect pipelines: Main → Enrichment
  main_task.connect_to(enrichment_task)

  puts "=" * 60
  puts "RUNNING PIPELINES"
  puts "=" * 60
  puts ""

  # Run main pipeline (will also trigger enrichment pipeline)
  main_pipeline.run

  puts "\n" + "=" * 60
  puts "RESULTS"
  puts "=" * 60

  puts "\nMain Pipeline Results: #{main_pipeline.results.size} items"
  main_pipeline.results.each do |item|
    puts "  Workflow #{item[:id]}: #{item[:priority]} priority"
  end

  puts "\nEnrichment Pipeline Results: #{enrichment_pipeline.results.size} items"
  
  # Group by type
  by_type = enrichment_pipeline.results.group_by { |r| r[:type] }
  puts "\nItems by type:"
  by_type.each do |type, items|
    puts "  #{type}: #{items.size} items"
  end

  # Show some samples
  puts "\nSample enriched items:"
  enrichment_pipeline.results.first(3).each do |item|
    puts "  Type: #{item[:type]}, Source: #{item[:source] || 'upstream'}, Enriched: #{item[:enriched_at] ? 'Yes' : 'No'}"
  end

  # Statistics
  puts "\n📊 Pipeline Statistics:"
  
  puts "\nMain Pipeline:"
  main_stats = main_task.implicit_pipeline.stats
  puts "  Total produced: #{main_stats.total_produced}"
  puts "  Total consumed: #{main_stats.total_consumed}"
  puts "  Runtime: #{main_stats.runtime.round(2)}s"

  puts "\nEnrichment Pipeline:"
  enrich_stats = enrichment_task.implicit_pipeline.stats
  puts "  Total produced: #{enrich_stats.total_produced}"
  puts "  Total consumed: #{enrich_stats.total_consumed}"
  puts "  Runtime: #{enrich_stats.runtime.round(2)}s"
  
  # Show producer stats from enrichment pipeline
  puts "\n  Producer breakdown:"
  [:cache_reference, :config_data].each do |producer_name|
    producer_stats = enrich_stats.stage_stats[producer_name]
    if producer_stats
      puts "    #{producer_name}: #{producer_stats.items_produced} items"
    end
  end

  puts "\n✓ Multi-pipeline with multiple producers example complete!"
  puts "\nKey points demonstrated:"
  puts "  ✓ Pipeline A generated 5 items and forwarded them to Pipeline B"
  puts "  ✓ Pipeline B has 2 additional producers (cache + config)"
  puts "  ✓ Pipeline B processed #{enrichment_pipeline.results.size} total items"
  puts "  ✓ All items were enriched and stored successfully"
end

