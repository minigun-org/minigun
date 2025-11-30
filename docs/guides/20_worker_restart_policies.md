# Worker Restart Policies

This guide covers the worker restart policies available for IPC fork executors. These policies allow you to automatically restart worker processes that crash or exit abnormally.

## Overview

When using `in_ipc_forks`, you can configure how the executor handles worker process failures:

```ruby
in_ipc_forks(4, restart_policy: :transient) do
  processor :work do |item, output|
    output << process(item)
  end
end
```

## Restart Policies

### `:never` (default)

Don't restart failed workers. If a worker crashes, it stays dead and its items may be lost.

```ruby
in_ipc_forks(4, restart_policy: :never) do
  processor :work do |item, output|
    output << process(item)
  end
end
```

**Use when:**
- Worker crashes are unexpected and indicate a bug
- You want to fail fast on errors
- Processing is idempotent and you'll retry the whole job

### `:transient`

Restart workers that exit abnormally (killed by signal or non-zero exit code). Workers that exit normally (exit code 0) are not restarted.

```ruby
in_ipc_forks(4, restart_policy: :transient) do
  processor :risky_work do |item, output|
    # If this crashes, worker will be restarted
    output << potentially_unstable_operation(item)
  end
end
```

**Use when:**
- Some operations may crash but are worth retrying
- Workers should recover from transient failures
- External dependencies may cause occasional crashes

### `:permanent`

Always restart workers that exit, regardless of exit status. Even workers that exit normally are restarted.

```ruby
in_ipc_forks(4, restart_policy: :permanent) do
  processor :continuous_work do |item, output|
    output << process(item)
  end
end
```

**Use when:**
- Workers should always be running during the stage
- You want maximum resilience
- Workers may exit normally but should continue

## Rate Limiting

To prevent restart storms, you can configure rate limits:

```ruby
in_ipc_forks(4,
  restart_policy: :transient,
  max_restarts: 3,        # Max restarts per worker
  restart_window: 60      # Time window in seconds
) do
  processor :work do |item, output|
    output << process(item)
  end
end
```

With these settings:
- Each worker can restart at most 3 times within any 60-second window
- If a worker exceeds this limit, it won't be restarted
- Each worker's restart count is tracked independently

### Default Values

| Option | Default | Description |
|--------|---------|-------------|
| `restart_policy` | `:never` | Restart behavior |
| `max_restarts` | `3` | Max restarts per worker |
| `restart_window` | `60` | Window in seconds |

## How It Works

1. **Worker Monitor Thread**: When `restart_policy` is not `:never`, a background thread monitors worker processes
2. **Exit Detection**: Uses `Process.wait2` with `WNOHANG` to non-blocking check for exited workers
3. **Policy Check**: Evaluates whether the exit status warrants a restart based on the policy
4. **Rate Limit Check**: Ensures the worker hasn't exceeded `max_restarts` in the `restart_window`
5. **Respawn**: Forks a new worker process with fresh IPC pipes
6. **Result Thread**: Starts a new result collection thread for the respawned worker

## Important Considerations

### Item Loss

When a worker crashes:
- The item currently being processed is lost
- Items queued for that worker may be lost
- This is **at-most-once** delivery

For **at-least-once** delivery, use cluster mode with `delivery_mode: :at_least_once`.

### Memory and Resources

- Respawned workers get fresh memory space
- IPC pipes are recreated for each respawned worker
- The parent process tracks all worker restarts for rate limiting

### Idempotency

If your processing isn't idempotent, be careful with restart policies:
- `:transient` may retry items that partially completed before crash
- Consider using external checkpointing for critical operations

## Complete Example

```ruby
class ResilientPipeline
  include Minigun::DSL

  pipeline do
    produce_each :items, -> { (1..100).to_a }

    # Workers restart on crashes, max 5 restarts per worker per minute
    in_ipc_forks(4,
      restart_policy: :transient,
      max_restarts: 5,
      restart_window: 60
    ) do
      processor :risky_work do |item, output|
        # Simulate occasional crashes
        raise "Random failure" if rand < 0.01

        output << expensive_calculation(item)
      end
    end

    consumer :save do |result|
      save_to_database(result)
    end
  end

  def expensive_calculation(item)
    # CPU-intensive work
    item * 2
  end

  def save_to_database(result)
    # Store result
  end
end

# Run with logging to see restart behavior
Minigun.logger.level = Logger::INFO
ResilientPipeline.new.run
```

## Monitoring

When restarts occur, they're logged at appropriate levels:

```
INFO  -- : [Minigun] Respawning worker 2 (policy: transient)
WARN  -- : [Minigun] Worker 2 (pid 12345) exited: signal 9
ERROR -- : [Minigun] Worker 2 exceeded max restarts (5 in 60s), not restarting
```

You can monitor restart behavior by setting:

```ruby
Minigun.logger.level = Logger::INFO
```

## Comparison with Cluster Mode

| Feature | IPC Fork + Restart | Cluster + At-Least-Once |
|---------|-------------------|------------------------|
| Delivery guarantee | At-most-once | At-least-once |
| Item tracking | None | In-flight tracking |
| Retry mechanism | Worker restart | Item requeue |
| Network support | Local only | Distributed |
| Complexity | Lower | Higher |

Choose IPC fork with restart policies for:
- Local processing with acceptable item loss
- CPU-intensive work that benefits from process isolation
- Simpler deployment without network coordination

Choose cluster mode with at-least-once for:
- Critical processing where no items can be lost
- Distributed processing across machines
- When you need item-level retry tracking
