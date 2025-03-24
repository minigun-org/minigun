# frozen_string_literal: true

require 'minigun'
require 'json'
require 'csv'

class DataEtlExample
  include Minigun::DSL

  # Configuration
  max_threads 2
  max_processes 1
  batch_size 3

  # Pipeline definition for a data ETL process
  pipeline do
    producer :extract_data do
      puts 'Extracting data from source...'

      # Simulated data records
      records = [
        { id: 1, name: 'Product A', price: 19.99, category: 'electronics', in_stock: true },
        { id: 2, name: 'Product B', price: 29.99, category: 'clothing', in_stock: false },
        { id: 3, name: 'Product C', price: 9.99, category: 'electronics', in_stock: true },
        { id: 4, name: 'Product D', price: 49.99, category: 'home', in_stock: true },
        { id: 5, name: 'Product E', price: 15.99, category: 'clothing', in_stock: true },
        { id: 6, name: 'Product F', price: 39.99, category: 'electronics', in_stock: false },
        { id: 7, name: 'Product G', price: 24.99, category: 'home', in_stock: true }
      ]

      records.each do |record|
        puts "Extracted record: #{record[:id]} - #{record[:name]}"
        emit(record)
      end
    end

    # Transform the data - price calculations and filtering
    processor :transform_data do |record|
      puts "Transforming record: #{record[:id]}"

      # Only process in-stock items
      if record[:in_stock]
        # Add tax
        tax_rate = 0.08
        record[:price_with_tax] = (record[:price] * (1 + tax_rate)).round(2)

        # Add discount for electronics
        if record[:category] == 'electronics'
          discount = 0.1
          record[:discounted_price] = (record[:price_with_tax] * (1 - discount)).round(2)
        end

        puts "Transformed record: #{record[:id]} - price with tax: $#{record[:price_with_tax]}"
        emit(record)
      else
        puts "Skipping out-of-stock record: #{record[:id]}"
      end
    end

    # Categorize data into different groups
    processor :categorize_data, to: :aggregate_data do |record|
      puts "Categorizing record: #{record[:id]} into #{record[:category]}"

      # Add a type field based on price
      record[:price_tier] = if record[:price] < 20
                              'budget'
                            elsif record[:price] < 40
                              'mid-range'
                            else
                              'premium'
                            end

      emit(record)
    end

    # Aggregate data by category
    accumulator :aggregate_data do |record|
      @categories ||= {}
      category = record[:category]

      @categories[category] ||= {
        count: 0,
        total_price: 0,
        records: []
      }

      @categories[category][:count] += 1
      @categories[category][:total_price] += record[:price]
      @categories[category][:records] << record

      # If we have enough records in a category, emit it
      if @categories[category][:count] >= 2
        result = {
          category: category,
          count: @categories[category][:count],
          avg_price: (@categories[category][:total_price] / @categories[category][:count]).round(2),
          items: @categories[category][:records].map { |r| r[:name] }
        }

        puts "Aggregated data for #{category}: #{result[:count]} records, avg price: $#{result[:avg_price]}"

        # Clear the records but keep the running totals
        processed_records = @categories[category][:records].dup
        @categories[category][:records] = []

        emit({ summary: result, records: processed_records })
      end
    end

    # Load data to destination
    consumer :load_data do |data|
      puts "Loading data for #{data[:summary][:category]} (#{data[:summary][:count]} records)"

      # Simulate writing to different output formats
      puts 'CSV output:'
      headers = %w[id name price category price_tier]
      csv_output = CSV.generate do |csv|
        csv << headers
        data[:records].each do |record|
          csv << [record[:id], record[:name], record[:price], record[:category], record[:price_tier]]
        end
      end
      puts csv_output

      puts 'JSON output:'
      json_output = JSON.pretty_generate(data[:summary])
      puts json_output

      puts 'Data loaded successfully.'
    end
  end

  before_run do
    puts 'Starting ETL process...'
  end

  after_run do
    puts 'ETL process completed!'
  end
end

# Run the task if executed directly
DataEtlExample.new.run if __FILE__ == $PROGRAM_NAME
