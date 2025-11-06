# frozen_string_literal: true

require_relative '../lib/minigun'
require 'json'

# ETL Pipeline Pattern
# Extract, Transform, Load with category-based aggregation
class EtlPipelineExample
  include Minigun::DSL

  attr_reader :load_stats

  def initialize
    @load_stats = { records_extracted: 0, records_transformed: 0, batches_loaded: 0 }
    @mutex = Mutex.new
  end

  pipeline do
    # EXTRACT: Read data from source
    producer :extract_data do |output|
      puts "\n#{'=' * 60}"
      puts 'ETL PIPELINE: Extract Phase'
      puts '=' * 60

      # Simulate extracting data from multiple sources
      records = [
        # Electronics
        { id: 1, name: 'Laptop Pro', price: 1299.99, category: 'electronics', in_stock: true, supplier: 'TechCorp' },
        { id: 2, name: 'Wireless Mouse', price: 29.99, category: 'electronics', in_stock: true, supplier: 'TechCorp' },
        { id: 3, name: '4K Monitor', price: 499.99, category: 'electronics', in_stock: false, supplier: 'DisplayCo' },
        { id: 4, name: 'USB-C Cable', price: 19.99, category: 'electronics', in_stock: true, supplier: 'TechCorp' },

        # Clothing
        { id: 5, name: 'Cotton T-Shirt', price: 24.99, category: 'clothing', in_stock: true, supplier: 'FashionHub' },
        { id: 6, name: 'Denim Jeans', price: 59.99, category: 'clothing', in_stock: true, supplier: 'FashionHub' },
        { id: 7, name: 'Winter Jacket', price: 149.99, category: 'clothing', in_stock: false, supplier: 'OutdoorGear' },

        # Home
        { id: 8, name: 'Coffee Maker', price: 89.99, category: 'home', in_stock: true, supplier: 'HomePlus' },
        { id: 9, name: 'Desk Lamp', price: 39.99, category: 'home', in_stock: true, supplier: 'HomePlus' },
        { id: 10, name: 'Storage Box Set', price: 34.99, category: 'home', in_stock: true, supplier: 'HomePlus' },

        # Books
        { id: 11, name: 'Learn Ruby', price: 44.99, category: 'books', in_stock: true, supplier: 'BookWorld' },
        { id: 12, name: 'Cookbook Deluxe', price: 29.99, category: 'books', in_stock: true, supplier: 'BookWorld' }
      ]

      records.each do |record|
        puts "📦 Extracted: #{record[:id]} - #{record[:name]} (#{record[:category]})"
        @mutex.synchronize { @load_stats[:records_extracted] += 1 }
        output << record
      end
    end

    # TRANSFORM: Clean, enrich, and validate data
    thread_pool(3) do
      processor :transform_data do |record, output|
        puts "⚙️  Transforming: #{record[:id]} - #{record[:name]}"

        # Filter: Skip out-of-stock items
        unless record[:in_stock]
          puts "   ⊘ Filtered out (out of stock): #{record[:id]}"
          next
        end

        # Enrich: Add calculated fields
        tax_rate = 0.08
        record[:price_with_tax] = (record[:price] * (1 + tax_rate)).round(2)

        # Enrich: Add discount for electronics
        if record[:category] == 'electronics'
          discount = 0.1
          record[:discounted_price] = (record[:price_with_tax] * (1 - discount)).round(2)
          record[:discount_applied] = true
        else
          record[:discount_applied] = false
        end

        # Enrich: Add price tier
        record[:price_tier] = if record[:price] < 30
                                'budget'
                              elsif record[:price] < 100
                                'mid-range'
                              else
                                'premium'
                              end

        # Enrich: Add timestamp
        record[:transformed_at] = Time.now.to_i

        puts "   ✓ Transformed: price=$#{record[:price]} → $#{record[:price_with_tax]} (tier: #{record[:price_tier]})"

        @mutex.synchronize { @load_stats[:records_transformed] += 1 }
        output << record
      end
    end

    # AGGREGATE: Group by category for batch loading
    accumulator :aggregate_by_category, max_size: 3 do |batch, output|
      # Group batch by category
      by_category = batch.group_by { |r| r[:category] }

      puts "\n📊 Aggregating batch:"
      by_category.each do |category, records|
        total_value = records.sum { |r| r[:price_with_tax] }
        avg_price = (total_value / records.size).round(2)

        puts "   #{category.ljust(15)} #{records.size} items, avg price: $#{avg_price}"
      end

      # Return the grouped data (accumulator automatically outputs this)
      output << by_category
    end

    # LOAD: Write to destination with per-batch processing
    cow_fork(2) do
      consumer :load_to_warehouse do |batch_by_category|
        puts "\n💾 Loading batch to data warehouse:"

        batch_by_category.each do |category, records|
          # Simulate loading to different tables
          puts "   Loading #{records.size} #{category} records..."

          # Generate summary
          summary = {
            category: category,
            record_count: records.size,
            total_value: records.sum { |r| r[:price_with_tax] }.round(2),
            average_price: (records.sum { |r| r[:price_with_tax] } / records.size).round(2),
            suppliers: records.map { |r| r[:supplier] }.uniq,
            price_tiers: records.group_by { |r| r[:price_tier] }.transform_values(&:size),
            discounted_items: records.count { |r| r[:discount_applied] }
          }

          # Simulate database write
          sleep(0.02)

          puts "   ✓ Loaded #{category}:"
          puts "     - Total value: $#{summary[:total_value]}"
          puts "     - Average price: $#{summary[:average_price]}"
          puts "     - Suppliers: #{summary[:suppliers].join(', ')}"
          puts "     - Price tiers: #{summary[:price_tiers].inspect}"
          puts "     - Discounted: #{summary[:discounted_items]} items"

          # Also write summary to JSON
          json_summary = JSON.pretty_generate(summary)
          puts "     - JSON summary: #{json_summary.lines.first.strip}..."
        end

        @mutex.synchronize { @load_stats[:batches_loaded] += 1 }
        puts '   ✓ Batch load complete'
      end
    end

    after_run do
      puts "\n#{'=' * 60}"
      puts 'ETL PIPELINE STATISTICS'
      puts '=' * 60
      puts "Records extracted: #{@load_stats[:records_extracted]}"
      puts "Records transformed: #{@load_stats[:records_transformed]}"
      puts "Batches loaded: #{@load_stats[:batches_loaded]}"
      puts "Transform rate: #{((@load_stats[:records_transformed].to_f / @load_stats[:records_extracted]) * 100).round(1)}%"
      puts "\nETL pipeline complete!"
      puts '=' * 60
    end
  end
end

# Run if executed directly
EtlPipelineExample.new.run if __FILE__ == $PROGRAM_NAME
