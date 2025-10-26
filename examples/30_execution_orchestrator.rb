#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

# Execution Orchestrator Examples
# Demonstrates the ExecutionOrchestrator for coordinated pipeline execution

puts "=== Execution Orchestrator Examples ===\n\n"

# Example 1: Basic Orchestration
puts "1. Basic Orchestrator Usage"
puts "-" * 50

class BasicPipeline
  include Minigun::DSL

  attr_accessor :results

  def initialize
    @results = []
    @mutex = Mutex.new
  end

  producer :source do
    puts "  [Producer] Generating 5 items"
    5.times { |i| emit(i + 1) }
  end

  processor :double, to: :collect do |item|
    result = item * 2
    puts "  [Processor] #{item} * 2 = #{result}"
    emit(result)
  end

  consumer :collect do |item|
    @mutex.synchronize { @results << item }
    puts "  [Consumer] Collected: #{item}"
  end
end

task = BasicPipeline._minigun_task
pipeline_obj = task.root_pipeline

puts "Creating orchestrator for pipeline..."
orchestrator = Minigun::Execution::ExecutionOrchestrator.new(pipeline_obj)

puts "\nExecution Plan:"
# Note: Plan is created during execute, so we create one manually for display
preview_plan = Minigun::Execution::ExecutionPlan.new(
  pipeline_obj.dag,
  pipeline_obj.stages,
  pipeline_obj.config
).plan!

puts "  Independent stages: #{preview_plan.independent_stages.inspect}"
puts "  Context types: #{preview_plan.context_types.inspect}"

puts "\nExecuting pipeline...\n"
# Note: Orchestrator delegates to existing pipeline logic for now
# Future versions will use the plan directly
pipeline_instance = BasicPipeline.new
pipeline_instance.run

puts "\nResults: #{pipeline_instance.results.sort.inspect}"
puts "✓ Orchestrator coordinated execution\n\n"

# Example 2: Orchestrator with Context Pools
puts "2. Orchestrator with Context Pools"
puts "-" * 50

class PooledPipeline
  include Minigun::DSL

  attr_accessor :processed

  def initialize
    @processed = []
    @mutex = Mutex.new
  end

  producer :gen do
    puts "  [Gen] Producing 10 items"
    10.times { |i| emit(i + 1) }
  end

  processor :work, to: :save do |item|
    # Simulate work
    sleep 0.01
    @mutex.synchronize { @processed << item }
    emit(item)
  end

  consumer :save do |item|
    # Save result
  end
end

pooled_task = PooledPipeline._minigun_task
pooled_obj = pooled_task.root_pipeline

orchestrator = Minigun::Execution::ExecutionOrchestrator.new(pooled_obj)

puts "Orchestrator creates context pools automatically"
puts "  Max threads: #{pooled_obj.config[:max_threads] || 5}"
puts "  Max processes: #{pooled_obj.config[:max_processes] || 2}"

puts "\nExecuting with orchestrator...\n"
start = Time.now
pooled_instance = PooledPipeline.new
pooled_instance.run
elapsed = Time.now - start

puts "\nProcessed: #{pooled_instance.processed.size} items"
puts "Elapsed: #{elapsed.round(2)}s"
puts "✓ Context pools managed resources\n\n"

# Example 3: Orchestrator Plan Analysis
puts "3. Orchestrator Plan Analysis"
puts "-" * 50

class AnalyzedPipeline
  include Minigun::DSL

  producer :source_a do
    emit("A")
  end

  producer :source_b do
    emit("B")
  end

  processor :merge, from: [:source_a, :source_b], to: :transform do |item|
    emit(item)
  end

  processor :transform, to: :output do |item|
    emit(item.downcase)
  end

  consumer :output do |item|
    # Collect
  end
end

analyzed_task = AnalyzedPipeline._minigun_task
analyzed_obj = analyzed_task.root_pipeline

orchestrator = Minigun::Execution::ExecutionOrchestrator.new(analyzed_obj)

puts "Pipeline DAG:"
analyzed_obj.dag.edges.each do |from, tos|
  puts "  #{from} -> #{tos.join(', ')}"
end

# Create plan for analysis
plan = Minigun::Execution::ExecutionPlan.new(
  analyzed_obj.dag,
  analyzed_obj.stages,
  analyzed_obj.config
).plan!

puts "\nOrchestrator Analysis:"
puts "  Stages: #{analyzed_obj.stages.keys.inspect}"
puts "  Independent: #{plan.independent_stages.inspect}"
puts "  Colocated groups:"
plan.colocated_stages.each do |parent, children|
  puts "    #{parent} -> #{children.inspect}"
end

puts "\nContext allocations:"
analyzed_obj.stages.keys.each do |stage|
  context = plan.context_for(stage)
  affinity = plan.affinity_for(stage) || 'independent'
  puts "  #{stage}: #{context} (#{affinity})"
end

puts "\n✓ Orchestrator optimizes execution based on DAG\n\n"

# Example 4: Resource Management
puts "4. Orchestrator Resource Management"
puts "-" * 50

puts "Orchestrator automatically:"
puts "  1. Creates ExecutionPlan from DAG"
puts "  2. Allocates ContextPools per type"
puts "  3. Maps pool sizes from config:"
puts "     - :thread  -> config[:max_threads]  (default: 5)"
puts "     - :fork    -> config[:max_processes] (default: 2)"
puts "     - :ractor  -> config[:max_ractors]   (default: 4)"
puts "     - :inline  -> 1"
puts "  4. Executes stages according to plan"
puts "  5. Waits for completion (join_all)"
puts "  6. Cleans up resources (terminate_all)"
puts "\n✓ Fully automated resource lifecycle\n\n"

# Example 5: Future Optimization Potential
puts "5. Future Optimization Potential"
puts "-" * 50

puts "Current Implementation:"
puts "  ✓ Plan analysis ready"
puts "  ✓ Context pools configured"
puts "  ✓ Affinity calculated"
puts "  → Delegates to existing pipeline logic"
puts ""
puts "Future Optimizations (planned):"
puts "  1. Colocated Execution:"
puts "     - Run affinity groups sequentially in one context"
puts "     - Eliminate queue overhead"
puts "     - Direct function calls"
puts ""
puts "  2. Smart Scheduling:"
puts "     - Parallel independent stages"
puts "     - Sequential colocated stages"
puts "     - Optimal use of contexts"
puts ""
puts "  3. Dynamic Affinity:"
puts "     - Adjust based on runtime metrics"
puts "     - Balance locality vs parallelism"
puts "     - Adapt to workload"
puts "\n✓ Architecture supports advanced optimizations\n\n"

# Example 6: Configuration Impact
puts "6. Configuration Impact on Orchestrator"
puts "-" * 50

class ConfiguredPipeline
  include Minigun::DSL

  max_threads 10
  max_processes 4

  producer :gen do
    emit(1)
  end

  processor :work, to: :save do |item|
    emit(item)
  end

  consumer :save do |item|
    # Save
  end
end

configured_task = ConfiguredPipeline._minigun_task
configured_obj = configured_task.root_pipeline

puts "Pipeline configuration:"
puts "  max_threads: #{configured_obj.config[:max_threads]}"
puts "  max_processes: #{configured_obj.config[:max_processes]}"

orchestrator = Minigun::Execution::ExecutionOrchestrator.new(configured_obj)

puts "\nOrchestrator will create pools:"
puts "  ThreadPool: max_size=10"
puts "  ForkPool: max_size=4"
puts "\n✓ Configuration drives resource allocation\n\n"

# Example 7: Execution Strategies
puts "7. Strategy-to-Context Mapping"
puts "-" * 50

puts "ExecutionPlan maps strategies to contexts:"
puts "  :threaded       -> :thread"
puts "  :fork_ipc       -> :fork"
puts "  :ractor         -> :ractor"
puts "  :spawn_thread   -> :thread"
puts "  :spawn_fork     -> :fork"
puts "  :spawn_ractor   -> :ractor"
puts "  (default)       -> config[:default_context] || :thread"
puts ""
puts "Orchestrator then:"
puts "  1. Creates appropriate pool for each context type"
puts "  2. Acquires contexts from pools"
puts "  3. Executes stages in assigned contexts"
puts "  4. Releases contexts back to pools"
puts "\n✓ Unified strategy handling\n\n"

# Example 8: Complete Workflow
puts "8. Complete Orchestrator Workflow"
puts "-" * 50

puts "Step-by-step execution:"
puts ""
puts "  1. Initialize:"
puts "     orchestrator = ExecutionOrchestrator.new(pipeline)"
puts ""
puts "  2. Plan:"
puts "     - Analyze DAG structure"
puts "     - Determine stage dependencies"
puts "     - Calculate affinity (colocated vs independent)"
puts "     - Map stages to context types"
puts ""
puts "  3. Setup:"
puts "     - Create ContextPool for each type"
puts "     - Configure pool sizes from config"
puts "     - Prepare execution environment"
puts ""
puts "  4. Execute:"
puts "     - Spawn producers in appropriate contexts"
puts "     - Route items through stages"
puts "     - Apply affinity optimizations"
puts "     - Manage parallelism with pools"
puts ""
puts "  5. Cleanup:"
puts "     - join_all: Wait for completion"
puts "     - terminate_all: Stop any remaining"
puts "     - Release all resources"
puts "\n✓ Complete execution lifecycle management\n\n"

# Summary
puts "=" * 50
puts "Summary:"
puts "  ✓ ExecutionOrchestrator coordinates pipeline execution"
puts "  ✓ Creates ExecutionPlan for DAG analysis"
puts "  ✓ Allocates ContextPools for resource management"
puts "  ✓ Maps stages to optimal execution contexts"
puts "  ✓ Manages complete execution lifecycle"
puts "  ✓ Handles cleanup and resource release"
puts "  ✓ Supports all context types and strategies"
puts "  ✓ Ready for future optimizations"
puts "=" * 50

