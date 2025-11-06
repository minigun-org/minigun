#!/usr/bin/env ruby
# frozen_string_literal: true

# Complex demo showcasing advanced pipeline patterns:
# - Broadcast fan-out (sending each item to multiple stages)
# - Round-robin distribution (load balancing across workers)
# - Fan-in (merging results from parallel paths)
# - Diamond patterns and complex routing
# - Multiple processing stages with varying latencies
#
# Run with: ruby examples/hud_complex_demo.rb

require_relative '../lib/minigun'
require_relative '../lib/minigun/hud'

class HudComplexDemoTask
  include Minigun::DSL

  pipeline do
    # Stage 1: Producer - generates work items
    # FAN-OUT to three parallel paths using broadcast routing
    producer :generator, to: %i[fast_path medium_path slow_path], routing: :broadcast do |output|
      puts 'Starting data generation...'
      puts "Press Ctrl+C or 'q' in the HUD to stop"

      counter = 0
      loop do
        # Generate items with metadata
        item = {
          id: counter,
          value: rand(1..1000),
          timestamp: Time.now.to_f
        }
        output << item
        counter += 1

        # Varying generation rate for interesting patterns
        sleep_time = 0.01 + (Math.sin(counter / 30.0).abs * 0.03)
        sleep sleep_time
      end
    end

    # ========== FAST PATH (Path A) ==========
    # Stage 2: Fast preprocessing
    processor :fast_path, threads: 4, to: :fast_transform do |item, output|
      item[:path] = 'Fast'
      item[:fast_check] = item[:value] < 500
      sleep rand(0.005..0.015)
      output << item
    end

    # Stage 3: Fast transformation
    processor :fast_transform, threads: 3, to: :fast_enrich do |item, output|
      item[:fast_result] = item[:value] * 2
      sleep rand(0.01..0.025)
      output << item
    end

    # Stage 4: Fast enrichment - FAN-OUT to round-robin workers
    processor :fast_enrich, threads: 2, to: %i[rr_worker_a rr_worker_b rr_worker_c], routing: :round_robin do |item, output|
      item[:enriched] = "fast_#{item[:id]}"
      sleep rand(0.015..0.03)
      output << item
    end

    # Stages 5-7: Round-robin workers (load balancing)
    # These will automatically FAN-IN to merger
    processor :rr_worker_a, threads: 2, to: :merger do |item, output|
      item[:worker] = 'A'
      sleep rand(0.02..0.04)
      output << item
    end

    processor :rr_worker_b, threads: 2, to: :merger do |item, output|
      item[:worker] = 'B'
      sleep rand(0.02..0.04)
      output << item
    end

    processor :rr_worker_c, threads: 2, to: :merger do |item, output|
      item[:worker] = 'C'
      sleep rand(0.02..0.04)
      output << item
    end

    # ========== MEDIUM PATH (Path B) ==========
    # Stage 8: Medium preprocessing
    processor :medium_path, threads: 3, to: :medium_analyze do |item, output|
      item[:path] = 'Medium'
      item[:category] = item[:value] / 100
      sleep rand(0.015..0.035)
      output << item
    end

    # Stage 9: Medium analysis
    processor :medium_analyze, threads: 4, to: :medium_validate do |item, output|
      item[:analyzed] = Math.sqrt(item[:value])
      sleep rand(0.025..0.05)
      output << item
    end

    # Stage 10: Medium validation - goes to merger (FAN-IN)
    processor :medium_validate, threads: 2, to: :merger do |item, output|
      item[:validated] = item[:analyzed] > 10
      sleep rand(0.02..0.045)
      output << item
    end

    # ========== SLOW PATH (Path C) ==========
    # Stage 11: Slow preprocessing
    processor :slow_path, threads: 2, to: :slow_compute do |item, output|
      item[:path] = 'Slow'
      item[:priority] = item[:value] > 750 ? 'high' : 'normal'
      sleep rand(0.03..0.06)
      output << item
    end

    # Stage 12: Intensive computation
    processor :slow_compute, threads: 5, to: :slow_optimize do |item, output|
      # Simulate expensive computation
      item[:computed] = Math.log(item[:value] + 1) * Math.sqrt(item[:value])
      sleep rand(0.04..0.08)
      output << item
    end

    # Stage 13: Optimization - goes to merger (FAN-IN)
    processor :slow_optimize, threads: 3, to: :merger do |item, output|
      item[:optimized] = item[:computed].round(2)
      sleep rand(0.035..0.07)
      output << item
    end

    # ========== FAN-IN POINT ==========
    # Stage 14: Merger - receives from all paths
    # This is the convergence point for fast_path, medium_path, and slow_path
    processor :merger, threads: 4, to: :postprocessor do |item, output|
      item[:merged_at] = Time.now.to_f
      item[:processing_time] = item[:merged_at] - item[:timestamp]
      sleep rand(0.01..0.03)
      output << item
    end

    # ========== FINAL STAGES ==========
    # Stage 15: Post-processor - final transformations
    processor :postprocessor, threads: 3, to: :batcher do |item, output|
      item[:completed] = true
      item[:total_stages] = 17
      sleep rand(0.015..0.04)
      output << item
    end

    # Stage 16: Accumulator - batch for efficient output
    accumulator :batcher, max_size: 20 do |batch, output|
      output << batch
    end

    # Stage 17: Consumer - final processing
    consumer :finalizer, threads: 2 do |_batch, _output|
      # Simulate batch processing with varying latency
      sleep 0.05 + rand(0.1)

      # Uncomment to see detailed batch info
      # paths = batch.map { |item| item[:path] }.tally
      # workers = batch.select { |item| item[:worker] }.map { |item| item[:worker] }.tally
      # puts "Batch: #{batch.size} items - Paths: #{paths.inspect} Workers: #{workers.inspect}"
    end
  end
end

# Display information banner
puts '=' * 80
puts 'MINIGUN COMPLEX HUD DEMO - ADVANCED PIPELINE PATTERNS'
puts '=' * 80
puts ''
puts 'This demo showcases a complex pipeline with 17 stages demonstrating:'
puts ''
puts 'Pipeline Architecture:'
puts ''
puts '  Stage 1: Generator'
puts '    └─> BROADCAST FAN-OUT to 3 parallel paths (each item goes to ALL paths)'
puts ''
puts '  ┌─── FAST PATH ───────────────────────────────────────┐'
puts '  │ 2. fast_path      → Quick preprocessing             │'
puts '  │ 3. fast_transform → Lightweight transformation      │'
puts '  │ 4. fast_enrich    → ROUND-ROBIN FAN-OUT to workers │'
puts '  │    ├─> 5. rr_worker_a (load balanced)              │'
puts '  │    ├─> 6. rr_worker_b (load balanced)              │'
puts '  │    └─> 7. rr_worker_c (load balanced)              │'
puts '  └─────────────────────────────────────────────────────┘'
puts ''
puts '  ┌─── MEDIUM PATH ─────────────────────────────────────┐'
puts '  │ 8.  medium_path     → Moderate preprocessing        │'
puts '  │ 9.  medium_analyze  → Analysis computation          │'
puts '  │ 10. medium_validate → Validation logic              │'
puts '  └─────────────────────────────────────────────────────┘'
puts ''
puts '  ┌─── SLOW PATH ───────────────────────────────────────┐'
puts '  │ 11. slow_path     → Heavy preprocessing             │'
puts '  │ 12. slow_compute  → Intensive computation (slowest) │'
puts '  │ 13. slow_optimize → Optimization step               │'
puts '  └─────────────────────────────────────────────────────┘'
puts ''
puts '  All paths FAN-IN to:'
puts '    14. merger        → Convergence point (receives from 5 sources)'
puts '    15. postprocessor → Final transformations'
puts '    16. batcher       → Accumulates into batches'
puts '    17. finalizer     → Consumes batches'
puts ''
puts 'Key Features:'
puts '  • BROADCAST fan-out: Each item processed by ALL 3 paths simultaneously'
puts '  • ROUND-ROBIN: Fast path items load-balanced across 3 workers'
puts '  • FAN-IN: Merger receives from 5 sources (3 workers + 2 paths)'
puts '  • Each input item generates 3 outputs (one per path)'
puts '  • Different latencies create interesting bottlenecks'
puts '  • Real-time visualization shows queue depths and throughput'
puts ''
puts 'Controls:'
puts '  • Press SPACE to pause/resume'
puts "  • Press 'h' for help"
puts "  • Press 'q' to quit (or Ctrl+C)"
puts '  • Use ↑/↓ to scroll through stages'
puts ''
puts 'Starting in 3 seconds...'
sleep 3

# Run the complex demo with HUD
begin
  Minigun::HUD.run_with_hud(HudComplexDemoTask)
rescue Interrupt
  puts "\nInterrupted by user"
end

puts "\nComplex demo complete!"
