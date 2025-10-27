#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

# Comprehensive test of named and unnamed pipelines at various nesting levels
class NestedPipelineVariations
  include Minigun::DSL

  attr_accessor :results

  def initialize
    @results = []
    @mutex = Mutex.new
  end

  # Top-level WITH name
  pipeline :top_level_with_name do
    producer :source_named do |output|
      output << "from_named_top"
    end

    # Nested WITHOUT name
    pipeline do
      processor :process_in_unnamed_nested do |item, output|
        output << "#{item}_processed"
      end
    end

    consumer :collect_named do |item|
      @mutex.synchronize { @results << item }
    end
  end

  # Top-level WITHOUT name (default pipeline)
  pipeline do
    producer :source_default do |output|
      output << "from_default_top"
    end

    # Nested WITH name
    pipeline :nested_with_name do
      processor :process_in_named_nested do |item, output|
        output << "#{item}_in_named"
      end

      # Nested 2 levels deep WITH name
      pipeline :doubly_nested_with_name do
        processor :deep_process_named do |item, output|
          output << "#{item}_deep_named"
        end
      end
    end

    # Nested 2 levels deep WITHOUT name
    pipeline do
      processor :level_1_unnamed do |item, output|
        output << "#{item}_level1"
      end

      pipeline do
        processor :level_2_unnamed do |item, output|
          output << "#{item}_level2"
        end
      end
    end

    consumer :collect_default do |item|
      @mutex.synchronize { @results << item }
    end
  end
end

if __FILE__ == $0
  puts "=== Nested Pipeline Variations ===\n\n"

  example = NestedPipelineVariations.new
  example.run

  puts "\n=== Results ===\n"
  puts "Results: #{example.results.sort.inspect}"

  # We should have results from both top-level pipelines
  has_named = example.results.any? { |r| r.include?("from_named_top") }
  has_default = example.results.any? { |r| r.include?("from_default_top") }

  puts "Has results from named top-level: #{has_named}"
  puts "Has results from default top-level: #{has_default}"

  success = has_named && has_default
  puts success ? "✓ Success!" : "✗ Failed"
end

