#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

# Example: Demand with Enumerator Producer
# Tests demand with lazy enumeration source
class DemandEnumeratorExample
  include Minigun::DSL

  attr_accessor :results, :generated_count

  def initialize
    @results = []
    @generated_count = Concurrent::AtomicFixnum.new(0)
    @mutex = Mutex.new
  end

  pipeline demand: true do
    # Enumerator producer - generates lazily using produce_each
    produce_each :source, (0...100)

    consumer :sink do |item|
      @mutex.synchronize { results << item }
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  puts "=== Demand with Enumerator Producer Example ===\n\n"
  puts "Demand works with lazy enumerator-based producers.\n\n"

  example = DemandEnumeratorExample.new
  example.run

  puts "Results: #{example.results.size} items processed"
  puts "Expected: 100 items"

  success = example.results.size == 100
  puts success ? "\n✓ Enumerator producer with demand works!" : "\n✗ Item count mismatch"
end
