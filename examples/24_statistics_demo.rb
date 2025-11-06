#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

# Simplified Statistics Demo
class StatisticsDemo
  include Minigun::DSL

  attr_accessor :results

  def initialize
    @results = []
  end

  pipeline do
    producer :generate do |output|
      puts '[Producer] Generating 20 items'
      20.times { |i| output << (i + 1) }
    end

    processor :process, to: :collect do |num, output|
      sleep(0.001) if num % 5 == 0 # Small delay every 5th item
      output << (num * 2)
    end

    consumer :collect do |num|
      @results << num
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  puts "=== Minigun Statistics Demo ===\n"

  demo = StatisticsDemo.new
  demo.run

  # Access the stats from instance task (not class task)
  task = demo._minigun_task
  pipeline = task.root_pipeline
  stats = pipeline.stats

  puts "\n📊 Pipeline Statistics:"
  puts "  Runtime: #{stats.runtime.round(2)}s"
  puts "  Total Produced: #{stats.total_produced}"
  puts "  Total Consumed: #{stats.total_consumed}"
  puts "  Throughput: #{stats.throughput.round(2)} items/s"

  if (bn = stats.bottleneck)
    puts "\n🔴 Bottleneck:"
    puts "  Stage: #{bn.stage_name}"
    puts "  Throughput: #{bn.throughput.round(2)} items/s"
  end

  puts "\n📈 Stage Details:"
  stats.stages_in_order.each do |stage_stats|
    puts "\n  #{stage_stats.stage_name}:"
    puts "    Runtime: #{stage_stats.runtime.round(3)}s"
    puts "    Total items: #{stage_stats.total_items}"
    puts "    Throughput: #{stage_stats.throughput.round(2)} items/s"

    puts "    Latency P50/P90/P95: #{(stage_stats.p50 * 1000).round(2)}ms / #{(stage_stats.p90 * 1000).round(2)}ms / #{(stage_stats.p95 * 1000).round(2)}ms" if stage_stats.latency_data?
  end

  puts "\n✓ Statistics demo complete!"
end
