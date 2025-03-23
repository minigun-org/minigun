# frozen_string_literal: true

require 'minigun'

class CowForkExample
  include Minigun::DSL

  pipeline do
    producer :generate_data do
      data = (1..10).map { |i| { id: i, name: "Item #{i}", values: Array.new(1000) { rand(100) } } }

      data.each_slice(2) do |batch|
        puts "Generating batch of #{batch.size} items"
        emit(batch)
      end
    end

    cow_fork :process_batch do |batch|
      # Process items in a child process with copy-on-write memory sharing
      puts "Processing batch of #{batch.size} items in COW fork process #{Process.pid}"
      puts "Items: #{batch.map { |i| i[:id] }.join(', ')}"

      # Show memory advantages of COW
      total_elements = batch.sum { |item| item[:values].size }
      puts "Processing #{total_elements} values without modifying them (COW advantage)"

      # Process items without modifying them (leveraging COW)
      result = batch.map do |item|
        {
          id: item[:id],
          sum: item[:values].sum,
          avg: item[:values].sum / item[:values].size.to_f
        }
      end

      puts "Processing complete: #{result.map { |r| "#{r[:id]}=#{r[:avg].round(2)}" }.join(', ')}"
    end
  end

  before_fork do
    puts 'Preparing to fork with COW...'
  end

  after_fork do
    puts "COW fork process #{Process.pid} initialized"
  end
end

# Run the task
CowForkExample.new.run if __FILE__ == $PROGRAM_NAME
