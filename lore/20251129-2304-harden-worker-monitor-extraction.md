# Harden: Worker Monitor Extraction

**Date:** 2025-11-29
**Context:** Refactoring IPC fork restart implementation

## Assessment

The restart/monitoring logic added to `IpcForkPoolExecutor` is functional but violates SRP. The following methods are all about worker monitoring and restart:

- `should_restart_worker?(process_status)`
- `restart_allowed?(worker_index)`
- `record_restart(worker_index)`
- `respawn_worker(dead_worker, result_threads)`
- `start_worker_monitor(result_threads)`
- `format_exit_status(status)`
- `validate_restart_policy(policy)`

These 7 methods plus state (`@restart_policy`, `@max_restarts`, `@restart_window`, `@worker_restarts`, `@restart_mutex`) should be extracted into a dedicated `WorkerMonitor` class.

## Refactor Plan

### 1. Create `WorkerMonitor` class

**File:** `lib/minigun/execution/worker_monitor.rb`

```ruby
module Minigun
  module Execution
    class WorkerMonitor
      RESTART_POLICIES = %i[never transient permanent].freeze

      def initialize(restart_policy:, max_restarts:, restart_window:)
        @restart_policy = validate_policy(restart_policy)
        @max_restarts = max_restarts
        @restart_window = restart_window
        @worker_restarts = {}
        @mutex = Mutex.new
        @shutdown_requested = false
      end

      def enabled?
        @restart_policy != :never
      end

      def should_restart?(process_status)
        # ... existing logic
      end

      def restart_allowed?(worker_index)
        # ... existing logic
      end

      def record_restart(worker_index)
        # ... existing logic
      end

      def request_shutdown
        @shutdown_requested = true
      end

      def format_exit_status(status)
        # ... existing logic
      end

      private

      def validate_policy(policy)
        # ... existing logic
      end
    end
  end
end
```

### 2. Update `IpcForkPoolExecutor`

- Remove the 7 methods and state
- Create `@worker_monitor` in initialize
- Delegate to monitor for restart decisions
- `start_worker_monitor` stays in executor (it needs access to workers/threads) but uses `@worker_monitor` for policy decisions

### 3. Benefits

- **SRP**: Executor handles work distribution, Monitor handles restart logic
- **Testable**: Can unit test restart logic without forking
- **Reusable**: Could potentially be used by other executor types in future
- **Cleaner**: IpcForkPoolExecutor reduced by ~100 lines

## Confidence

**95%+ confident** this is a slam-dunk improvement:
- Clear separation of concerns
- No behavioral changes
- Existing tests will continue to pass
- Makes the code more maintainable

## Decision

**Proceeding with automatic refactor.**
