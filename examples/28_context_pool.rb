#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

# Context Pool Examples
# Demonstrates resource management with context pools

puts "=== Context Pool Examples ===\n\n"

# Example 1: Basic Pool Usage
puts "1. Basic Context Pool"
puts "-" * 50

pool = Minigun::Execution::ContextPool.new(type: :thread, max_size: 3)
puts "Created pool: type=:thread, max_size=3"
puts "Active count: #{pool.active_count}"
puts "At capacity?: #{pool.at_capacity?}\n\n"

# Acquire contexts
ctx1 = pool.acquire('task-1')
ctx2 = pool.acquire('task-2')
puts "Acquired 2 contexts"
puts "Active count: #{pool.active_count}"
puts "At capacity?: #{pool.at_capacity?}\n\n"

# Execute work
ctx1.execute { sleep 0.1; "result-1" }
ctx2.execute { sleep 0.1; "result-2" }
puts "Executed tasks in both contexts"

# Join and release
result1 = ctx1.join
result2 = ctx2.join
puts "Results: #{result1}, #{result2}"

pool.release(ctx1)
pool.release(ctx2)
puts "Released contexts back to pool"
puts "Active count: #{pool.active_count}\n\n"

# Example 2: Pool Capacity Management
puts "2. Pool Capacity Management"
puts "-" * 50

limited_pool = Minigun::Execution::ContextPool.new(type: :thread, max_size: 3)
puts "Created pool with max_size=3\n"

# Acquire up to capacity
contexts = []
3.times do |i|
  ctx = limited_pool.acquire("task-#{i}")
  contexts << ctx
  puts "  Acquired context #{i+1}/3, active: #{limited_pool.active_count}, at_capacity?: #{limited_pool.at_capacity?}"
end
puts "\n"

# Execute in all contexts
contexts.each_with_index do |ctx, i|
  ctx.execute { sleep 0.05; "result-#{i}" }
end

# Wait for all
limited_pool.join_all
puts "All contexts completed"
puts "Active count after join_all: #{limited_pool.active_count}\n\n"

# Example 3: Pooled Parallel Execution
puts "3. Pooled Parallel Execution (10 tasks, 5 workers)"
puts "-" * 50

worker_pool = Minigun::Execution::ContextPool.new(type: :thread, max_size: 5)
puts "Pool: 5 concurrent workers\n"

results = []
mutex = Mutex.new

start_time = Time.now

# Process 10 tasks with pool of 5 workers
10.times do |i|
  ctx = worker_pool.acquire("task-#{i}")
  ctx.execute do
    sleep 0.1  # Simulate work
    result = "task-#{i}-complete"
    mutex.synchronize { results << result }
    result
  end
end

worker_pool.join_all
elapsed = Time.now - start_time

puts "Completed 10 tasks"
puts "Elapsed: #{elapsed.round(2)}s (expected ~0.2s with 5 workers)"
puts "Results: #{results.size} items"
puts "✓ Pool managed parallelism efficiently\n\n"

# Example 4: Different Pool Types
puts "4. Different Pool Types"
puts "-" * 50

inline_pool = Minigun::Execution::ContextPool.new(type: :inline, max_size: 2)
thread_pool = Minigun::Execution::ContextPool.new(type: :thread, max_size: 2)

puts "Inline Pool:"
inline_ctx = inline_pool.acquire('inline-task')
inline_ctx.execute { puts "  Executing inline (synchronous)"; 42 }
result = inline_ctx.join
puts "  Result: #{result}"
inline_pool.release(inline_ctx)

puts "\nThread Pool:"
thread_ctx = thread_pool.acquire('thread-task')
thread_ctx.execute do
  puts "  Executing in thread (concurrent)"
  sleep 0.05
  84
end
result = thread_ctx.join
puts "  Result: #{result}"
thread_pool.release(thread_ctx)
puts "\n"

# Example 5: Context Reuse (Inline Only)
puts "5. Context Reuse"
puts "-" * 50

reuse_pool = Minigun::Execution::ContextPool.new(type: :inline, max_size: 2)
puts "Note: Only inline contexts are reused (threads/forks always fresh)\n"

# First acquisition
ctx_a = reuse_pool.acquire('task-a')
ctx_a_id = ctx_a.object_id
ctx_a.execute { "result-a" }
ctx_a.join
reuse_pool.release(ctx_a)
puts "Acquired and released context A (id: #{ctx_a_id})"

# Second acquisition - should reuse for inline
ctx_b = reuse_pool.acquire('task-b')
ctx_b_id = ctx_b.object_id
ctx_b.execute { "result-b" }
ctx_b.join
reuse_pool.release(ctx_b)
puts "Acquired and released context B (id: #{ctx_b_id})"

if ctx_a_id == ctx_b_id
  puts "✓ Context reused (inline type)"
else
  puts "✗ Different contexts (thread/fork type)"
end
puts "\n"

# Example 6: Bulk Operations
puts "6. Bulk Operations (join_all, terminate_all)"
puts "-" * 50

bulk_pool = Minigun::Execution::ContextPool.new(type: :thread, max_size: 5)

# Start multiple long-running tasks
puts "Starting 5 tasks..."
5.times do |i|
  ctx = bulk_pool.acquire("long-task-#{i}")
  ctx.execute do
    sleep 0.2  # Simulate work
    "result-#{i}"
  end
end

puts "Active contexts: #{bulk_pool.active_count}"
puts "Waiting for all to complete..."

bulk_pool.join_all
puts "All completed!"
puts "Active contexts: #{bulk_pool.active_count}\n\n"

# Example 7: Emergency Termination
puts "7. Emergency Termination"
puts "-" * 50

term_pool = Minigun::Execution::ContextPool.new(type: :thread, max_size: 3)

# Start tasks that would run forever
3.times do |i|
  ctx = term_pool.acquire("infinite-#{i}")
  ctx.execute do
    loop do
      sleep 0.1
    end
  end
end

puts "Started 3 infinite loops"
sleep 0.05
puts "Active contexts: #{term_pool.active_count}"
puts "Terminating all..."

term_pool.terminate_all
puts "All terminated!"
puts "Active contexts: #{term_pool.active_count}\n\n"

# Example 8: Real-World Pattern - Batch Processing
puts "8. Real-World: Batch Processing with Pool"
puts "-" * 50

# Simulate processing 20 items with pool of 4 workers
items = (1..20).to_a
processed = []
mutex = Mutex.new
batch_pool = Minigun::Execution::ContextPool.new(type: :thread, max_size: 4)

puts "Processing 20 items with 4-worker pool\n"
start = Time.now

items.each do |item|
  ctx = batch_pool.acquire("process-#{item}")
  ctx.execute do
    # Simulate processing
    sleep 0.05
    result = item * 2
    mutex.synchronize { processed << result }
    result
  end
end

batch_pool.join_all
elapsed = Time.now - start

puts "Processed: #{processed.size} items"
puts "Elapsed: #{elapsed.round(2)}s"
puts "Throughput: #{(items.size / elapsed).round(1)} items/sec"
puts "Expected: ~0.25s (20 items / 4 workers * 0.05s)\n\n"

# Summary
puts "=" * 50
puts "Summary:"
puts "  ✓ Context pools manage resource limits"
puts "  ✓ acquire() gets a context, release() returns it"
puts "  ✓ join_all() waits for all contexts"
puts "  ✓ terminate_all() stops all contexts"
puts "  ✓ Only inline contexts are reused"
puts "  ✓ Thread-safe for concurrent access"
puts "  ✓ Prevents resource exhaustion"
puts "=" * 50

