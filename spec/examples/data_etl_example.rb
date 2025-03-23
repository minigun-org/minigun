# frozen_string_literal: true

require 'minigun'

class DataETLExample
  include Minigun::DSL

  max_threads 4
  max_processes 2

  pipeline do
    producer :extract do
      # Extract data from source
      # Simulate database.each_batch
      data = [
        [{ id: 1, name: 'Product A', price: 10.99 },
         { id: 2, name: 'Product B', price: 24.99 }],
        [{ id: 3, name: 'Product C', price: 5.99 },
         { id: 4, name: 'Product D', price: 15.99 }],
        [{ id: 5, name: 'Product E', price: 8.99 },
         { id: 6, name: 'Product F', price: 12.99 }]
      ]

      data.each do |batch|
        puts "Extracting batch of #{batch.size} records"
        emit(batch)
      end
    end

    processor :transform do |batch|
      # Transform the data
      puts "Transforming batch of #{batch.size} records"

      transformed_batch = batch.map do |row|
        {
          product_id: row[:id],
          product_name: row[:name].upcase,
          price_usd: row[:price],
          price_eur: (row[:price] * 0.92).round(2),
          timestamp: Time.now.to_i
        }
      end

      emit(transformed_batch)
    end

    consumer :load do |batch|
      # Load data to destination
      puts "Loading batch of #{batch.size} records to destination"

      # Simulate database insertion
      batch.each do |record|
        puts "  Inserted: #{record[:product_id]} - #{record[:product_name]} ($#{record[:price_usd]}, €#{record[:price_eur]})"
      end

      puts 'Batch successfully loaded'
    end
  end
end

# Run the task
DataETL.new.run if __FILE__ == $PROGRAM_NAME
