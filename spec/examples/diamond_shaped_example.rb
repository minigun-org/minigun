# frozen_string_literal: true

require 'minigun'

class DiamondShapedExample
  include Minigun::DSL

  pipeline do
    producer :data_source do
      # Sample data items
      data_items = [
        { id: 1, value: 'apple', valid: true },
        { id: 2, value: 'banana', valid: true },
        { id: 3, value: 'invalid', valid: false },
        { id: 4, value: 'orange', valid: true }
      ]

      data_items.each { |item| emit(item) }
    end

    # Split to parallel processors
    processor :validate, from: :data_source, to: %i[transform_a transform_b] do |item|
      puts "Validating item: #{item[:id]}"
      emit(item) if item[:valid]
    end

    # Parallel transformations
    processor :transform_a, from: :validate, to: :combine do |item|
      puts "Transform A processing item: #{item[:id]}"
      emit({ id: item[:id], value: item[:value], transform: 'A', processed: true })
    end

    processor :transform_b, from: :validate, to: :combine do |item|
      puts "Transform B processing item: #{item[:id]}"
      emit({ id: item[:id], value: item[:value], transform: 'B', processed: true })
    end

    # Rejoin for final processing
    processor :combine, from: %i[transform_a transform_b] do |item|
      @results ||= {}
      key = item[:id]
      @results[key] ||= []
      @results[key] << item

      if @results[key].size >= 2
        result = combine_results(@results[key])
        @results.delete(key)
        emit(result)
      end
    end

    consumer :store_results, from: :combine do |result|
      puts "Storing final result: #{result}"
    end
  end

  private

  def combine_results(items)
    # Simple example of combining results
    {
      id: items.first[:id],
      value: items.first[:value],
      transforms: items.map { |i| i[:transform] }.join('+'),
      combined: true
    }
  end
end

# Run the task
DiamondShapedExample.new.run if __FILE__ == $PROGRAM_NAME
