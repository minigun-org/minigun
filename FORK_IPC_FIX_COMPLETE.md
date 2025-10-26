# Fork IPC Fix - COW Pattern with Tempfiles

## Problem
When using `process_per_batch` (COW fork pattern), child processes cannot mutate parent's instance variables because they have their own memory space.

## Solution
Use tempfiles for IPC between parent and child processes.

## Pattern

### 1. Initialize tempfile
```ruby
def initialize
  @results = []
  @temp_file = Tempfile.new(['minigun_results', '.txt'])
  @temp_file.close
end

def cleanup
  File.unlink(@temp_file.path) if @temp_file && File.exist?(@temp_file.path)
end
```

### 2. Write to tempfile in forked process
```ruby
process_per_batch(max: 2) do
  consumer :save do |batch|
    File.open(@temp_file.path, 'a') do |f|
      f.flock(File::LOCK_EX)
      batch.each { |item| f.puts(item) }
      f.flock(File::LOCK_UN)
    end
  end
end
```

### 3. Read from tempfile after run
```ruby
after_run do
  if File.exist?(@temp_file.path)
    @results = File.readlines(@temp_file.path).map(&:strip)
  end
end
```

### 4. Cleanup in ensure block
```ruby
if __FILE__ == $0
  example = MyExample.new
  begin
    example.run
  ensure
    example.cleanup
  end
end
```

## Fixed Examples
- ✅ 09_strategy_per_stage.rb
- ✅ 17_database_connection_hooks.rb
- ✅ 18_resource_cleanup_hooks.rb
- ✅ 19_statistics_gathering.rb
- ✅ 20_error_handling_hooks.rb
- ⏳ 21_inline_hook_procs.rb
- ⏳ 35_nested_contexts.rb
- ⏳ 36_batch_and_process.rb

## Remaining Failures (7 total, down from 11)
- 3 fork-related example tests (21, 35, 36)
- 1 hook ordering test (stage_hooks_advanced_spec.rb:55)
- 1 emit_to_stage cross-context test (emit_to_stage_spec.rb:246)
- 2 inheritance tests (inheritance_spec.rb:488,495)

## Summary
Fork IPC with `process_per_batch` (COW pattern) requires tempfiles for parent-child communication.
Forked child processes have isolated memory and cannot mutate parent's instance variables.
The tempfile pattern with file locking provides thread-safe IPC.

