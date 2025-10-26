#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

# Execution Context Examples
# Demonstrates the four types of execution contexts and their characteristics

puts "=== Execution Context Examples ===\n\n"

# Example 1: InlineContext - No concurrency, same thread
puts "1. InlineContext (synchronous, same thread)"
puts "-" * 50

inline_ctx = Minigun::Execution.create_context(:inline, 'sync-task')
puts "Created InlineContext: #{inline_ctx.name} (type: #{inline_ctx.type})"

inline_ctx.execute do
  puts "  Executing in thread: #{Thread.current.object_id}"
  puts "  Computing: 2 + 2"
  4
end

result = inline_ctx.join
puts "  Result: #{result}"
puts "  Context alive?: #{inline_ctx.alive?}"
puts "  ✓ Inline execution completes immediately\n\n"

# Example 2: ThreadContext - Lightweight concurrency
puts "2. ThreadContext (lightweight parallelism)"
puts "-" * 50

thread_ctx = Minigun::Execution.create_context(:thread, 'worker-1')
puts "Created ThreadContext: #{thread_ctx.name} (type: #{thread_ctx.type})"

thread_ctx.execute do
  puts "  Executing in thread: #{Thread.current.object_id}"
  puts "  Simulating work..."
  sleep 0.1
  puts "  Work complete!"
  "thread-result"
end

puts "  Context alive?: #{thread_ctx.alive?}"
result = thread_ctx.join
puts "  Result: #{result}"
puts "  Context alive?: #{thread_ctx.alive?}"
puts "  ✓ Thread execution with concurrency\n\n"

# Example 3: ForkContext - Process isolation
if Process.respond_to?(:fork)
  puts "3. ForkContext (process isolation)"
  puts "-" * 50

  fork_ctx = Minigun::Execution.create_context(:fork, 'isolated-worker')
  puts "Created ForkContext: #{fork_ctx.name} (type: #{fork_ctx.type})"

  main_pid = Process.pid
  fork_ctx.execute do
    child_pid = Process.pid
    puts "  Parent PID: #{main_pid}, Child PID: #{child_pid}"
    puts "  Running in separate process!"
    sleep 0.1
    { pid: child_pid, result: "fork-result" }
  end

  puts "  Context alive?: #{fork_ctx.alive?}"
  sleep 0.05
  puts "  Context alive? (after 50ms): #{fork_ctx.alive?}"

  result = fork_ctx.join
  puts "  Result: #{result.inspect}"
  puts "  ✓ Fork execution with process isolation\n\n"
else
  puts "3. ForkContext (skipped - fork not available on this platform)\n\n"
end

# Example 4: RactorContext - True parallelism (Ruby 3.0+)
puts "4. RactorContext (true parallelism, Ruby 3+)"
puts "-" * 50

ractor_ctx = Minigun::Execution.create_context(:ractor, 'ractor-worker')
puts "Created RactorContext: #{ractor_ctx.name} (type: #{ractor_ctx.type})"

ractor_ctx.execute do
  puts "  Executing in ractor"
  sleep 0.1
  "ractor-result"
end

puts "  Context alive?: #{ractor_ctx.alive?}"
result = ractor_ctx.join
puts "  Result: #{result}"
puts "  ✓ Ractor execution (or thread fallback)\n\n"

# Example 5: Parallel Execution with Multiple Contexts
puts "5. Parallel Execution (5 workers)"
puts "-" * 50

start_time = Time.now
contexts = 5.times.map do |i|
  ctx = Minigun::Execution.create_context(:thread, "worker-#{i}")
  ctx.execute do
    sleep 0.1  # Simulate work
    "result-#{i}"
  end
  ctx
end

puts "  Started 5 concurrent workers"
results = contexts.map(&:join)
elapsed = Time.now - start_time

puts "  Results: #{results.inspect}"
puts "  Elapsed time: #{elapsed.round(2)}s"
puts "  ✓ All workers completed in parallel\n\n"

# Example 6: Error Handling
puts "6. Error Handling and Propagation"
puts "-" * 50

error_ctx = Minigun::Execution.create_context(:thread, 'error-task')
error_ctx.execute do
  sleep 0.05
  raise StandardError, "Something went wrong!"
end

begin
  error_ctx.join
  puts "  ✗ Should have raised an error"
rescue StandardError => e
  puts "  ✓ Error caught: #{e.message}"
  puts "  ✓ Errors propagate correctly from contexts\n\n"
end

# Example 7: Context Termination
puts "7. Context Termination"
puts "-" * 50

long_ctx = Minigun::Execution.create_context(:thread, 'long-running')
long_ctx.execute do
  puts "  Starting long-running task..."
  sleep 10  # This will be interrupted
  "never-reached"
end

sleep 0.05
puts "  Context alive?: #{long_ctx.alive?}"
puts "  Terminating context..."
long_ctx.terminate
puts "  Context terminated"
puts "  Context alive?: #{long_ctx.alive?}"
puts "  ✓ Context terminated successfully\n\n"

# Example 8: Context Type Comparison
puts "8. Context Type Characteristics"
puts "-" * 50
puts "  | Type    | Concurrency | Memory      | Use Case               |"
puts "  |---------|-------------|-------------|------------------------|"
puts "  | Inline  | None        | Shared      | Testing, debugging     |"
puts "  | Thread  | Lightweight | Shared      | I/O-bound tasks        |"
puts "  | Fork    | Process     | Isolated    | CPU-bound, isolation   |"
puts "  | Ractor  | True        | Separate    | CPU-bound (Ruby 3+)    |"
puts "\n"

# Summary
puts "=" * 50
puts "Summary:"
puts "  ✓ Inline:  Synchronous, no overhead"
puts "  ✓ Thread:  Concurrent, shared memory"
puts "  ✓ Fork:    Isolated, separate processes"
puts "  ✓ Ractor:  Parallel, message passing"
puts "  ✓ All contexts support: execute, join, alive?, terminate"
puts "  ✓ Unified API for all concurrency models"
puts "=" * 50

