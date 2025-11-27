#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

# Pipeline Inheritance Example
# Demonstrates how child classes can extend parent pipelines

# === Example 1: Extending unnamed (default) pipeline ===
class BaseTask
  include Minigun::DSL

  attr_accessor :results

  def initialize
    @results = []
  end

  pipeline do
    producer :source do |output|
      puts "[Base] Producing: 1, 2, 3"
      [1, 2, 3].each { |n| output << n }
    end

    processor :double do |n, output|
      result = n * 2
      puts "[Base] Double: #{n} -> #{result}"
      output << result
    end

    consumer :collect do |n|
      puts "[Base] Collect: #{n}"
      @results << n
    end
  end
end

class ExtendedTask < BaseTask
  # This pipeline block is MERGED with parent's unnamed pipeline
  # because it's the first unnamed pipeline
  pipeline do
    processor :triple do |n, output|
      result = n * 3
      puts "[Child] Triple: #{n} -> #{result}"
      output << result
    end

    # Reroute to insert triple between double and collect
    reroute_stage :double, to: :triple
    reroute_stage :triple, to: :collect
  end
end

class SkipStageTask < BaseTask
  # This also merges with parent's unnamed pipeline
  pipeline do
    # Skip the double stage entirely
    reroute_stage :source, to: :collect
  end
end

# === Example 2: Extending named pipelines ===
class NamedPipelineBase
  include Minigun::DSL

  attr_accessor :results_a, :results_b

  def initialize
    @results_a = []
    @results_b = []
  end

  pipeline :pipeline_a do
    producer :source_a do |output|
      puts "[Base A] Producing: 10, 20"
      [10, 20].each { |n| output << n }
    end

    consumer :collect_a do |n|
      puts "[Base A] Collect: #{n}"
      @results_a << n
    end
  end

  pipeline :pipeline_b do
    producer :source_b do |output|
      puts "[Base B] Producing: 100, 200"
      [100, 200].each { |n| output << n }
    end

    consumer :collect_b do |n|
      puts "[Base B] Collect: #{n}"
      @results_b << n
    end
  end
end

class ExtendedNamedPipeline < NamedPipelineBase
  # Extend pipeline_a by declaring it again
  pipeline :pipeline_a do
    processor :process_a do |n, output|
      result = n + 5
      puts "[Child A] Process: #{n} -> #{result}"
      output << result
    end

    reroute_stage :source_a, to: :process_a
    reroute_stage :process_a, to: :collect_a
  end

  # pipeline_b is inherited as-is (not extended)
end

# === Example 3: Multiple unnamed pipelines (only first is merged) ===
class MultipleUnnamedBase
  include Minigun::DSL

  attr_accessor :results

  def initialize
    @results = []
  end

  pipeline do
    producer :main_source do |output|
      puts "[Main] Producing: A, B"
      ['A', 'B'].each { |c| output << c }
    end

    consumer :main_collect do |c|
      puts "[Main] Collect: #{c}"
      @results << c
    end
  end
end

class MultipleUnnamedChild < MultipleUnnamedBase
  # First unnamed pipeline: MERGES with parent
  pipeline do
    processor :uppercase do |c, output|
      result = c.upcase
      puts "[Child] Uppercase: #{c} -> #{result}"
      output << result
    end

    reroute_stage :main_source, to: :uppercase
    reroute_stage :uppercase, to: :main_collect
  end

  # Second unnamed pipeline: ISOLATED (does not merge)
  pipeline do
    producer :extra_source do |output|
      puts "[Extra] Producing: X, Y"
      ['X', 'Y'].each { |c| output << c }
    end

    consumer :extra_collect do |c|
      puts "[Extra] Collect: #{c}"
      @results << "extra_#{c}"
    end
  end
end

if __FILE__ == $0
  puts "=== Pipeline Inheritance Example ===\n\n"

  puts "--- Example 1a: Base Task ---"
  base = BaseTask.new
  base.run
  puts "Results: #{base.results.inspect}"
  puts "Expected: [2, 4, 6] (doubled)"
  puts base.results == [2, 4, 6] ? "✓ Pass" : "✗ Fail"

  puts "\n--- Example 1b: Extended Task (insert triple stage) ---"
  extended = ExtendedTask.new
  extended.run
  puts "Results: #{extended.results.inspect}"
  puts "Expected: [6, 12, 18] (double then triple)"
  puts extended.results == [6, 12, 18] ? "✓ Pass" : "✗ Fail"

  puts "\n--- Example 1c: Skip Stage Task ---"
  skip = SkipStageTask.new
  skip.run
  puts "Results: #{skip.results.inspect}"
  puts "Expected: [1, 2, 3] (skip double)"
  puts skip.results == [1, 2, 3] ? "✓ Pass" : "✗ Fail"

  puts "\n--- Example 2a: Named Pipeline Base ---"
  named_base = NamedPipelineBase.new
  named_base.run
  puts "Results A: #{named_base.results_a.inspect}"
  puts "Results B: #{named_base.results_b.inspect}"
  puts "Expected A: [10, 20], Expected B: [100, 200]"
  puts (named_base.results_a == [10, 20] && named_base.results_b == [100, 200]) ? "✓ Pass" : "✗ Fail"

  puts "\n--- Example 2b: Extended Named Pipeline (only pipeline_a extended) ---"
  extended_named = ExtendedNamedPipeline.new
  extended_named.run
  puts "Results A: #{extended_named.results_a.inspect}"
  puts "Results B: #{extended_named.results_b.inspect}"
  puts "Expected A: [15, 25] (processed), Expected B: [100, 200] (unchanged)"
  puts (extended_named.results_a == [15, 25] && extended_named.results_b == [100, 200]) ? "✓ Pass" : "✗ Fail"

  puts "\n--- Example 3: Multiple Unnamed Pipelines ---"
  multi = MultipleUnnamedChild.new
  multi.run
  puts "Results: #{multi.results.sort.inspect}"
  puts "Expected: ['A', 'B', 'extra_X', 'extra_Y'] (first merged, second isolated)"
  puts multi.results.sort == ['A', 'B', 'extra_X', 'extra_Y'].sort ? "✓ Pass" : "✗ Fail"

  puts "\n=== Key Concepts ==="
  puts "• First unnamed pipeline in child: MERGES with parent's unnamed pipeline"
  puts "• Named pipeline in child with same name: EXTENDS parent's named pipeline"
  puts "• Subsequent unnamed pipelines: ISOLATED (don't merge)"
  puts "• Allows natural inheritance: children can add stages and reroute parent's stages"
  puts "\n✓ Pipeline inheritance complete!"
end

