# Fork IPC Debugging Session - Oct 26, 2025

## Problem Identified
When using `process_per_batch` (Copy-on-Write fork pattern), forked child processes cannot mutate parent's instance variables because each process has isolated memory space. This caused `@results`, `@fork_results`, etc. arrays to remain empty in the parent after child processes completed.

## Root Cause
```ruby
# THIS DOES NOT WORK in forked processes:
process_per_batch(max: 2) do
  consumer :save do |batch|
    @results << batch  # ❌ Child process memory, never reaches parent!
  end
end
```

## Solution: Tempfile IPC Pattern
Use temporary files with file locking for thread-safe IPC between parent and child processes:

```ruby
def initialize
  @temp_file = Tempfile.new(['minigun_results', '.txt'])
  @temp_file.close
end

process_per_batch(max: 2) do
  consumer :save do |batch|
    File.open(@temp_file.path, 'a') do |f|
      f.flock(File::LOCK_EX)
      batch.each { |item| f.puts(item) }
      f.flock(File::LOCK_UN)
    end
  end
end

after_run do
  if File.exist?(@temp_file.path)
    @results = File.readlines(@temp_file.path).map(&:strip)
  end
end
```

## Test Results
- **Before**: 11 failures (all fork-related)
- **After**: 7 failures (5 fixed, 3 fork examples + 4 other tests remaining)

## Fixed Examples (5/8)
- ✅ 09_strategy_per_stage.rb
- ✅ 17_database_connection_hooks.rb (also fixed `after_fork` event logging)
- ✅ 18_resource_cleanup_hooks.rb (also fixed `after_fork` event logging)
- ✅ 19_statistics_gathering.rb (PIDs + results via 2 tempfiles)
- ✅ 20_error_handling_hooks.rb

## Remaining Work (7 failures)

### Fork IPC Examples (3)
- ⏳ 21_inline_hook_procs.rb
- ⏳ 35_nested_contexts.rb
- ⏳ 36_batch_and_process.rb

### Other Tests (4)
- `stage_hooks_advanced_spec.rb:55` - Hook execution order
- `emit_to_stage_spec.rb:246` - Cross-context routing
- `inheritance_spec.rb:488,495` - Base publisher inheritance (2 tests)

## Key Insights
1. **COW Fork vs Process Pool**: `process_per_batch` spawns NEW processes per batch (COW), while `processes(N)` would maintain a pool with IPC pipes.
2. **File Locking**: `f.flock(File::LOCK_EX)` ensures thread-safe writes when multiple forks write concurrently.
3. **After-Run Hook**: Perfect place to read tempfiles after all child processes complete.
4. **Event Logging**: `after_fork` hooks also need tempfiles since they run in child process.

## Next Steps
1. Apply same tempfile pattern to remaining 3 fork examples
2. Investigate hook ordering test failure
3. Debug cross-context `emit_to_stage` issue
4. Fix inheritance tests (likely also fork-related)

## Environment
- Platform: WSL (Ubuntu on Windows)
- Ruby: 3.4.4
- Test Suite: 362 examples, 7 failures, 3 pending (Ractor tests skipped as flaky)

