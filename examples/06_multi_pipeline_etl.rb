#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

# Multi-Pipeline ETL Example
# Demonstrates Extract -> Transform -> Load pattern with three separate pipelines
class MultiPipelineETL
  include Minigun::DSL

  attr_accessor :extracted, :transformed, :loaded_db, :loaded_cache

  def initialize
    @extracted = []
    @transformed = []
    @loaded_db = []
    @loaded_cache = []
    @mutex = Mutex.new
  end

  # Pipeline 1: Extract - Fetches raw data
  pipeline :extract, to: :transform do
    producer :fetch_data do |output|
      puts '[Extract] Fetching data from source...'
      5.times do |i|
        output << { id: i, value: i * 10 }
      end
    end

    consumer :output do |item, output|
      @mutex.synchronize { extracted << item }
      output << item # Send to next pipeline
    end
  end

  # Pipeline 2: Transform - Cleans and transforms data
  pipeline :transform, to: %i[load_db load_cache] do
    processor :clean do |item, output|
      puts "[Transform] Cleaning item #{item[:id]}"
      output << item.merge(cleaned: true)
    end

    processor :enrich do |item, output|
      puts "[Transform] Enriching item #{item[:id]}"
      output << item.merge(enriched_at: Time.now)
    end

    consumer :output do |item, output|
      @mutex.synchronize { transformed << item }
      output << item # Send to both load pipelines
    end
  end

  # Pipeline 3a: Load to Database
  pipeline :load_db do
    consumer :save_to_db do |item|
      puts "[Load:DB] Saving item #{item[:id]} to database"
      @mutex.synchronize { loaded_db << item }
    end
  end

  # Pipeline 3b: Load to Cache (runs in parallel with load_db)
  pipeline :load_cache do
    consumer :save_to_cache do |item|
      puts "[Load:Cache] Caching item #{item[:id]}"
      @mutex.synchronize { loaded_cache << item }
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  puts "=== Multi-Pipeline ETL Example ===\n\n"

  etl = MultiPipelineETL.new
  etl.run

  puts "\n=== Results ===\n"
  puts "Extracted: #{etl.extracted.size} items"
  puts "Transformed: #{etl.transformed.size} items"
  puts "Loaded to DB: #{etl.loaded_db.size} items"
  puts "Loaded to Cache: #{etl.loaded_cache.size} items"
  puts "\nAll pipelines completed successfully! ✓"
end
