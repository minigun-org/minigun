#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

# Test of named and unnamed pipelines at the top level
# Note: Deeply nested pipelines (pipeline inside pipeline) require named pipelines
class NestedPipelineVariations
  include Minigun::DSL

  attr_accessor :results

  def initialize
    @results = []
    @mutex = Mutex.new
  end

  # Top-level named pipeline
  pipeline :pipeline_a do
    producer :source_a do |output|
      output << 'from_pipeline_a'
    end

    processor :process_a do |item, output|
      output << "#{item}_processed"
    end

    consumer :collect_a do |item|
      @mutex.synchronize { @results << item }
    end
  end

  # Top-level unnamed pipeline (default)
  pipeline do
    producer :source_default do |output|
      output << 'from_default'
    end

    processor :process_default do |item, output|
      output << "#{item}_transformed"
    end

    consumer :collect_default do |item|
      @mutex.synchronize { @results << item }
    end
  end

  # Another named pipeline
  pipeline :pipeline_b do
    producer :source_b do |output|
      output << 'from_pipeline_b'
    end

    consumer :collect_b do |item|
      @mutex.synchronize { @results << item }
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  puts "=== Nested Pipeline Variations ===\n\n"

  example = NestedPipelineVariations.new
  example.run

  puts "\n=== Results ===\n"
  puts "Results: #{example.results.sort.inspect}"

  # We should have results from all pipelines
  has_a = example.results.any? { |r| r.include?('from_pipeline_a') }
  has_default = example.results.any? { |r| r.include?('from_default') }
  has_b = example.results.any? { |r| r.include?('from_pipeline_b') }

  puts "Has results from pipeline_a: #{has_a}"
  puts "Has results from default pipeline: #{has_default}"
  puts "Has results from pipeline_b: #{has_b}"

  success = has_a && has_default && has_b
  puts success ? '✓ Success!' : '✗ Failed'
end
