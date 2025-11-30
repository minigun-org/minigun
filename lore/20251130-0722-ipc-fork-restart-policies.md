# IPC Fork Restart Policies

## Overview

The `in_ipc_forks` execution context supports three restart policies that control how workers are handled when they exit:

## Restart Policies

### `:never` (default)
Workers are **not restarted** when they exit. If a worker crashes, it stays dead and its work capacity is lost.

```ruby
in_ipc_forks(4, restart_policy: :never) do
  # Workers stay dead after any exit
end
```

### `:transient`
Workers are restarted **only on abnormal exits** (non-zero exit code or signal). Workers that exit cleanly with `exit(0)` are not restarted.

```ruby
in_ipc_forks(4, restart_policy: :transient, max_restarts: 3, restart_window: 60) do
  # Workers restarted on crash, not on clean exit
end
```

**Use cases:**
- Fault tolerance for workers that might crash due to bad input
- Resilience against transient errors (network timeouts, resource exhaustion)

### `:permanent`
Workers are restarted **on any exit**, including normal exits (exit code 0).

```ruby
in_ipc_forks(4, restart_policy: :permanent, max_restarts: 5, restart_window: 60) do
  # Workers always restarted, even on clean exit
end
```

**Use cases:**
- **Long-running daemon-style workers** - Workers that should always be running regardless of how they exit (e.g., polling an external queue that exits when empty but should restart to check again)
- **Self-terminating workers** - Workers designed to exit after a certain amount of work to release memory or refresh state:
  ```ruby
  processor :memory_conscious do |item, output|
    @count ||= 0
    @count += 1
    exit(0) if @count >= 1000  # Exit cleanly, will be restarted
    output << process(item)
  end
  ```
- **Connection-based workers** - Workers maintaining persistent connections that exit cleanly on disconnect but should reconnect

## Rate Limiting

All restart policies support rate limiting to prevent restart storms:

- `max_restarts` - Maximum number of restarts allowed within the window (default: 3)
- `restart_window` - Time window in seconds for counting restarts (default: 60)

When a worker exceeds the restart limit, it stays dead to prevent infinite restart loops.

## Examples

See the example files:
- `examples/140_ipc_fork_restart_never.rb` - Default behavior, no restarts
- `examples/141_ipc_fork_restart_transient.rb` - Restart on crashes only
- `examples/142_ipc_fork_restart_permanent.rb` - Always restart
- `examples/143_ipc_fork_restart_rate_limit.rb` - Rate limiting demonstration
