# frozen_string_literal: true

require 'minigun'

class QueueBasedRoutingExampleExample
  include Minigun::DSL

  pipeline do
    producer :source do
      items = [
        { id: 1, name: 'Item 1', priority: :high },
        { id: 2, name: 'Item 2', priority: :low },
        { id: 3, name: 'Item 3', priority: :high },
        { id: 4, name: 'Item 4', priority: :low },
        { id: 5, name: 'Item 5', priority: :medium }
      ]

      items.each { |item| emit(item) }
    end

    processor :route, to: %i[high_priority low_priority] do |item|
      puts "Routing item #{item[:id]} with priority #{item[:priority]}"

      if item[:priority] == :high
        emit_to_queue(:high_priority, item)
      else
        emit_to_queue(:low_priority, item)
      end
    end

    processor :high_priority, queues: [:high_priority] do |item|
      # Process high priority items
      puts "HIGH PRIORITY: Processing #{item[:name]}"
      emit("Processed high priority item: #{item[:id]}")
    end

    processor :low_priority, queues: [:low_priority] do |item|
      # Process low priority items
      puts "LOW PRIORITY: Processing #{item[:name]}"
      emit("Processed low priority item: #{item[:id]}")
    end

    consumer :results, from: %i[high_priority low_priority] do |result|
      puts "Final result: #{result}"
    end
  end
end

# Run the task
QueueBasedRoutingExample.new.run if __FILE__ == $PROGRAM_NAME
