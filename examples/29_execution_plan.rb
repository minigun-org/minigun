#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

# Execution Plan Examples
# Demonstrates how ExecutionPlan analyzes DAGs and determines execution affinity

puts "=== Execution Plan Examples ===\n\n"

# Example 1: Simple Sequential Pipeline
puts "1. Sequential Pipeline (Affinity Analysis)"
puts "-" * 50

class SimplePipeline
  include Minigun::DSL

  producer :source do
    3.times { |i| emit(i + 1) }
  end

  processor :double, to: :output do |item|
    emit(item * 2)
  end

  consumer :output do |item|
    # Collect
  end
end

# Access the class-level task and pipeline
task = SimplePipeline._minigun_task
pipeline_obj = task.root_pipeline

# Create execution plan
plan = Minigun::Execution::ExecutionPlan.new(
  pipeline_obj.dag,
  pipeline_obj.stages,
  pipeline_obj.config
).plan!

puts "DAG: #{pipeline_obj.dag.edges.map { |from, tos| "#{from} -> #{tos.join(', ')}" }.join('; ')}"
puts "\nExecution Plan:"
puts "  source:  context=#{plan.context_for(:source)}, affinity=#{plan.affinity_for(:source) || 'independent'}"
puts "  double:  context=#{plan.context_for(:double)}, affinity=#{plan.affinity_for(:double) || 'independent'}"
puts "  output:  context=#{plan.context_for(:output)}, affinity=#{plan.affinity_for(:output) || 'independent'}"

puts "\nAffinity Groups:"
plan.affinity_groups.each do |parent, children|
  if parent
    puts "  #{parent} (colocated with): #{children.inspect}"
  else
    puts "  Independent: #{children.inspect}"
  end
end

puts "\n✓ Sequential stages colocate for efficiency\n\n"

# Example 2: Fan-Out Pipeline (Multiple Upstream)
puts "2. Fan-Out Pipeline (Multiple Upstream)"
puts "-" * 50

class FanOutPipeline
  include Minigun::DSL

  producer :source_a do
    emit("A")
  end

  producer :source_b do
    emit("B")
  end

  processor :merge, from: [:source_a, :source_b], to: :output do |item|
    emit(item)
  end

  consumer :output do |item|
    # Collect
  end
end

fanout_task = FanOutPipeline._minigun_task
fanout_obj = fanout_task.root_pipeline

plan = Minigun::Execution::ExecutionPlan.new(
  fanout_obj.dag,
  fanout_obj.stages,
  fanout_obj.config
).plan!

puts "DAG: Multiple sources -> merge -> output"
puts "\nExecution Plan:"
puts "  source_a: context=#{plan.context_for(:source_a)}, affinity=#{plan.affinity_for(:source_a) || 'independent'}"
puts "  source_b: context=#{plan.context_for(:source_b)}, affinity=#{plan.affinity_for(:source_b) || 'independent'}"
puts "  merge:    context=#{plan.context_for(:merge)}, affinity=#{plan.affinity_for(:merge) || 'independent'}"
puts "  output:   context=#{plan.context_for(:output)}, affinity=#{plan.affinity_for(:output) || 'independent'}"

puts "\n✓ Merge stage is independent (multiple upstream sources)\n\n"

# Example 3: Pipeline with Accumulator
puts "3. Pipeline with Accumulator"
puts "-" * 50

class AccumulatorPipeline
  include Minigun::DSL

  producer :source do
    5.times { |i| emit(i) }
  end

  processor :transform, to: :batch do |item|
    emit(item * 2)
  end

  accumulator :batch, max_size: 3, to: :consume

  consumer :consume do |batch|
    # Process batch
  end
end

accum_task = AccumulatorPipeline._minigun_task
accum_obj = accum_task.root_pipeline

plan = Minigun::Execution::ExecutionPlan.new(
  accum_obj.dag,
  accum_obj.stages,
  accum_obj.config
).plan!

puts "DAG: source -> transform -> batch (accumulator) -> consume"
puts "\nExecution Plan:"
puts "  source:    context=#{plan.context_for(:source)}, affinity=#{plan.affinity_for(:source) || 'independent'}"
puts "  transform: context=#{plan.context_for(:transform)}, affinity=#{plan.affinity_for(:transform) || 'independent'}"
puts "  batch:     context=#{plan.context_for(:batch)}, affinity=#{plan.affinity_for(:batch) || 'independent'}"
puts "  consume:   context=#{plan.context_for(:consume)}, affinity=#{plan.affinity_for(:consume) || 'independent'}"

puts "\n✓ Consumer is independent (accumulator creates batching boundary)\n\n"

# Example 4: Explicit Strategy Override
puts "4. Explicit Strategy Override"
puts "-" * 50

class StrategyPipeline
  include Minigun::DSL

  producer :source do
    emit(1)
  end

  # Explicit fork strategy
  processor :heavy, strategy: :fork_ipc, to: :output do |item|
    emit(item * 2)
  end

  consumer :output do |item|
    # Collect
  end
end

strategy_task = StrategyPipeline._minigun_task
strategy_obj = strategy_task.root_pipeline

plan = Minigun::Execution::ExecutionPlan.new(
  strategy_obj.dag,
  strategy_obj.stages,
  strategy_obj.config
).plan!

puts "DAG: source -> heavy (fork_ipc strategy) -> output"
puts "\nExecution Plan:"
puts "  source: context=#{plan.context_for(:source)}, affinity=#{plan.affinity_for(:source) || 'independent'}"
puts "  heavy:  context=#{plan.context_for(:heavy)}, affinity=#{plan.affinity_for(:heavy) || 'independent'}"
puts "  output: context=#{plan.context_for(:output)}, affinity=#{plan.affinity_for(:output) || 'independent'}"

puts "\n✓ Explicit strategy forces independent execution\n\n"

# Example 5: Context Type Analysis
puts "5. Context Type Analysis"
puts "-" * 50

class MixedPipeline
  include Minigun::DSL

  producer :source do
    emit(1)
  end

  processor :thread_work, strategy: :threaded, to: :fork_work do |item|
    emit(item)
  end

  processor :fork_work, strategy: :fork_ipc, to: :ractor_work do |item|
    emit(item)
  end

  processor :ractor_work, strategy: :ractor, to: :output do |item|
    emit(item)
  end

  consumer :output do |item|
    # Done
  end
end

mixed_task = MixedPipeline._minigun_task
mixed_obj = mixed_task.root_pipeline

plan = Minigun::Execution::ExecutionPlan.new(
  mixed_obj.dag,
  mixed_obj.stages,
  mixed_obj.config
).plan!

puts "Pipeline with mixed strategies"
puts "\nContext Types Used:"
plan.context_types.each do |type|
  puts "  - #{type}"
end

puts "\nPer-Stage Contexts:"
[:source, :thread_work, :fork_work, :ractor_work, :output].each do |stage|
  puts "  #{stage}: #{plan.context_for(stage)}"
end

puts "\n✓ Plan tracks all context types needed\n\n"

# Example 6: Affinity Groups
puts "6. Affinity Groups (Colocated vs Independent)"
puts "-" * 50

class GroupedPipeline
  include Minigun::DSL

  producer :gen do
    emit(1)
  end

  processor :step1, to: :step2 do |item|
    emit(item)
  end

  processor :step2, to: :step3 do |item|
    emit(item)
  end

  processor :step3, to: :output do |item|
    emit(item)
  end

  consumer :output do |item|
    # Done
  end
end

grouped_task = GroupedPipeline._minigun_task
grouped_obj = grouped_task.root_pipeline

plan = Minigun::Execution::ExecutionPlan.new(
  grouped_obj.dag,
  grouped_obj.stages,
  grouped_obj.config
).plan!

puts "Pipeline: gen -> step1 -> step2 -> step3 -> output"
puts "\nIndependent Stages:"
puts "  #{plan.independent_stages.inspect}"

puts "\nColocated Stages:"
plan.colocated_stages.each do |parent, children|
  puts "  #{parent}: #{children.inspect}"
end

puts "\n✓ Long chains colocate for efficiency\n\n"

# Example 7: Colocated Check
puts "7. Colocated Stage Checking"
puts "-" * 50

puts "Using the sequential pipeline from Example 1..."
simple_task = SimplePipeline._minigun_task
pipeline_obj = simple_task.root_pipeline
plan = Minigun::Execution::ExecutionPlan.new(
  pipeline_obj.dag,
  pipeline_obj.stages,
  pipeline_obj.config
).plan!

puts "\nColocated Checks:"
puts "  double colocated with source?: #{plan.colocated?(:double, :source)}"
puts "  output colocated with double?: #{plan.colocated?(:output, :double)}"
puts "  output colocated with source?: #{plan.colocated?(:output, :source)}"

puts "\n✓ Can query affinity relationships\n\n"

# Example 8: Plan Optimization Benefits
puts "8. Execution Plan Benefits"
puts "-" * 50

puts "Affinity Rules:"
puts "  1. Single upstream + producer → COLOCATE (same context)"
puts "  2. Multiple upstream → INDEPENDENT (own context)"
puts "  3. Accumulator upstream → INDEPENDENT (batching boundary)"
puts "  4. Explicit strategy → INDEPENDENT (respect user choice)"
puts "  5. PipelineStage upstream → INDEPENDENT (separate execution)"
puts ""
puts "Benefits of Colocated Execution:"
puts "  ✓ No queue overhead"
puts "  ✓ No marshaling cost"
puts "  ✓ Better cache locality"
puts "  ✓ Direct function calls"
puts "  ✓ Faster for small operations"
puts ""
puts "Benefits of Independent Execution:"
puts "  ✓ True parallelism"
puts "  ✓ Isolation"
puts "  ✓ Resource control"
puts "  ✓ Better for CPU-bound work"
puts "\n"

# Summary
puts "=" * 50
puts "Summary:"
puts "  ✓ ExecutionPlan analyzes DAG structure"
puts "  ✓ Determines optimal execution contexts"
puts "  ✓ Calculates affinity (colocated vs independent)"
puts "  ✓ Respects explicit strategy overrides"
puts "  ✓ Optimizes for data locality when beneficial"
puts "  ✓ Groups stages for efficient execution"
puts "  ✓ Identifies required context types"
puts "=" * 50

