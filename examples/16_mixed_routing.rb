#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

# Mixed Routing Example
# Demonstrates combining explicit routing (with to:) and sequential routing
class MixedRoutingExample
  include Minigun::DSL

  attr_accessor :from_a, :from_b, :final

  def initialize
    @from_a = []
    @from_b = []
    @final = []
    @mutex = Mutex.new
  end

  pipeline do
    # Explicit routing: producer fans out to two paths
    producer :generate, to: [:path_a, :path_b] do
      puts "[Producer] Generating 3 items"
      3.times { |i| emit(i) }
    end

    # Path A: Explicit routing to collect
    processor :path_a, to: :collect do |num|
      result = num * 10
      puts "[Path A] Processing #{num} → #{result} (explicit route to :collect)"
      @mutex.synchronize { from_a << num }
      emit(result)
    end

    # Path B: Sequential routing (will connect to next stage: transform)
    processor :path_b do |num|
      result = num * 100
      puts "[Path B] Processing #{num} → #{result} (sequential to :transform)"
      @mutex.synchronize { from_b << num }
      emit(result)
    end

    # Transform: Sequential connection from path_b, explicit routing to collect
    processor :transform, to: :collect do |num|
      result = num + 1
      puts "[Transform] Processing #{num} → #{result} (explicit route to :collect)"
      emit(result)
    end

    # Consumer: Receives from both path_a (explicit) and transform (explicit)
    consumer :collect do |num|
      puts "[Collect] Received: #{num}"
      @mutex.synchronize { final << num }
    end
  end
end

if __FILE__ == $0
  puts "=== Mixed Routing Example ===\n\n"
  puts "This demonstrates combining explicit and sequential routing:"
  puts "  • Producer explicitly routes to [:path_a, :path_b]"
  puts "  • path_a explicitly routes to :collect"
  puts "  • path_b uses sequential routing to :transform"
  puts "  • transform explicitly routes to :collect\n\n"

  puts "Flow diagram:"
  puts "                    ┌─→ path_a (to: :collect) ─→ collect"
  puts "  generate (to:...) ┤"
  puts "                    └─→ path_b → transform (to: :collect) → collect\n\n"

  example = MixedRoutingExample.new
  example.run

  puts "\n=== Results ===\n"
  puts "Items from Path A: #{example.from_a.sort.inspect}"
  puts "Items from Path B: #{example.from_b.sort.inspect}"
  puts "Final results: #{example.final.sort.inspect}"

  puts "\nExpected final results:"
  puts "  • From Path A: 0*10=0, 1*10=10, 2*10=20"
  puts "  • From Path B→Transform: (0*100)+1=1, (1*100)+1=101, (2*100)+1=201"
  puts "  • Combined: #{[0, 1, 10, 20, 101, 201].inspect}"

  success = example.final.sort == [0, 1, 10, 20, 101, 201]
  puts "\nVerification: #{success ? '✓' : '✗'}"

  puts "\n=== Key Concepts ===\n"
  puts "• Explicit routing (to: :target) takes precedence"
  puts "• Sequential routing fills gaps where explicit routing is not defined"
  puts "• You can mix both styles in the same pipeline"
  puts "• This provides flexibility for complex routing patterns"
  puts "\n✓ Mixed routing complete!"
end

