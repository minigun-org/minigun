# Supervision Analysis and Worker Restart Implementation

**Date:** 2025-11-29
**Context:** Evaluating whether a supervision tree is needed for Minigun

## Analysis Summary

After reviewing the clustering implementation, CoW/IPC executors, and Minigun's architecture, the conclusion is:

**A full Erlang-style supervision tree is NOT needed for Minigun's batch pipeline use case.**

### Key Insight

In Minigun's architecture, the **coordinator/pipeline is the job runner itself**. When it fails:
- Items in the input queue are lost (no persistence)
- In-flight items may be lost
- The pipeline must be restarted externally

This is fundamentally different from Erlang/OTP where supervision trees manage long-lived services. Minigun pipelines are finite batch jobs.

### What Was Implemented Instead

#### 1. IPC Fork Worker Restart Policy

Added configurable restart policies for IPC fork workers:

```ruby
in_ipc_forks(4, restart_policy: :transient, max_restarts: 3, restart_window: 60) do
  processor :risky_work do |item, output|
    output << potentially_crashing_operation(item)
  end
end
```

**Restart Policies:**
- `:never` (default) - Don't restart failed workers
- `:transient` - Restart workers that exit abnormally (signal or non-zero exit)
- `:permanent` - Always restart workers that exit for any reason

**Rate Limiting:**
- `max_restarts: N` - Maximum restarts per worker before giving up
- `restart_window: N` - Time window (seconds) for counting restarts

**Files Changed:**
- `lib/minigun/execution/executor.rb` - Added restart logic to `IpcForkPoolExecutor`
- `lib/minigun/dsl.rb` - Updated `in_ipc_forks` DSL method
- `lib/minigun/worker.rb` - Pass restart options to executor

#### 2. Production Patterns Documentation

Created comprehensive guide at `docs/guides/19_production_patterns.md` covering:

- Reliable worker processing with restart policies
- Persistent input sources (database, Redis, file checkpointing)
- External orchestration (Kubernetes, systemd, Sidekiq)
- Graceful shutdown handling
- Monitoring and alerting patterns
- Anti-patterns to avoid

### Why NOT a HA Coordinator

Initially attempted to implement `HACoordinator` with Raft-style leader election. **Removed because:**

1. **Mid-job failover is impossible** without persistent queues
   - Items in memory are lost when coordinator crashes
   - Standby has no state to continue from

2. **Cold failover provides limited value**
   - Can only help for *next* job
   - External orchestration (K8s, systemd) handles this better

3. **Complexity vs. benefit trade-off**
   - Full Raft/Paxos adds significant complexity
   - Users who need HA should use:
     - Persistent message queues (Redis, Kafka)
     - External job schedulers with retry

### What Minigun Already Has

| Feature | Location | Purpose |
|---------|----------|---------|
| Worker heartbeat | `Cluster::Worker` | Detect disconnected workers |
| `at_least_once` delivery | `Cluster::DeliveryTracker` | Retry failed items |
| Graceful shutdown | `Runner`, `Pipeline` | Clean termination |
| IPC fork restart (NEW) | `IpcForkPoolExecutor` | Respawn crashed workers |

### Recommended Production Patterns

1. **Worker crashes** → Use `restart_policy: :transient` for IPC forks
2. **Network failures** → Use `delivery_mode: :at_least_once` for clusters
3. **Pipeline crashes** → Use persistent input sources (DB, Redis)
4. **Job restart** → Use external orchestration (K8s, systemd, Sidekiq)

### Test Coverage

Added `spec/unit/execution/ipc_fork_restart_spec.rb` with tests for:
- Restart policy validation
- Should restart logic for each policy
- Rate limiting (max_restarts, restart_window)
- End-to-end restart behavior

### Files Added/Modified

**Added:**
- `docs/guides/19_production_patterns.md`
- `spec/unit/execution/ipc_fork_restart_spec.rb`

**Modified:**
- `lib/minigun/execution/executor.rb` - IpcForkPoolExecutor restart logic
- `lib/minigun/dsl.rb` - in_ipc_forks restart options
- `lib/minigun/worker.rb` - Pass restart options

**Removed (after reconsidering):**
- `lib/minigun/cluster/ha_coordinator.rb` - Wrong approach for batch pipelines
