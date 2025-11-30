# Resumability Analysis: User-Side vs Built-In

**Date:** 2025-11-30
**Context:** Should pipeline resumability be a user concern or framework feature?

---

## The Question

When a pipeline crashes mid-execution, should Minigun:
1. **User-side**: Leave resumability entirely to users (current approach)
2. **Built-in**: Provide framework-level checkpointing and resume

---

## Analysis: Arguments For Each Approach

### User-Side Resumability (Current)

**Advantages:**
1. **Simplicity** - Framework stays lightweight, no storage dependencies
2. **Flexibility** - Users choose their own persistence (Redis, Postgres, files, etc.)
3. **Domain knowledge** - Users know what "resume" means for their data
4. **No abstraction mismatch** - Different pipelines have different resumability needs
5. **Idempotency requirement** - Forces users to design idempotent stages (good practice)

**Disadvantages:**
1. **Boilerplate** - Every user reimplements checkpointing
2. **Error-prone** - Easy to get wrong (race conditions, partial writes)
3. **Inconsistent patterns** - No standard way to do it
4. **Lost items** - In-flight items lost on crash without extra work

### Built-In Resumability

**Advantages:**
1. **Consistency** - Standard pattern across all pipelines
2. **Less boilerplate** - Framework handles the hard parts
3. **Battle-tested** - One well-tested implementation
4. **Better defaults** - Safer out-of-the-box behavior

**Disadvantages:**
1. **Storage dependency** - Framework needs to persist state somewhere
2. **Complexity** - Checkpoint coordination is hard
3. **Performance overhead** - Checkpointing adds latency
4. **Abstraction leakage** - Not all workloads need/want resumability
5. **Opinionated** - Forces a particular model of "resumability"

---

## Key Insight: What Does "Resume" Even Mean?

Different pipelines have fundamentally different resumability semantics:

### Case 1: File Processing Pipeline
```ruby
producer :files do |output|
  Dir.glob('*.csv').each { |f| output << f }
end
```
**Resume means:** Skip already-processed files
**State needed:** Set of processed filenames

### Case 2: Database Row Processing
```ruby
producer :rows do |output|
  User.where(status: 'pending').find_each { |u| output << u }
end
```
**Resume means:** Query already handles it (only pending rows)
**State needed:** None (database is the state)

### Case 3: API Pagination
```ruby
producer :pages do |output|
  cursor = nil
  loop do
    page = api.fetch(cursor: cursor)
    page.items.each { |item| output << item }
    cursor = page.next_cursor
    break unless cursor
  end
end
```
**Resume means:** Start from last cursor position
**State needed:** Last cursor value

### Case 4: Kafka Consumer
```ruby
producer :kafka do |output|
  consumer.each_message { |msg| output << msg }
end
```
**Resume means:** Kafka handles it (committed offsets)
**State needed:** Kafka manages internally

### Case 5: One-Shot Batch
```ruby
producer :batch do |output|
  100.times { |i| output << i }
end
```
**Resume means:** Nothing - just rerun from scratch
**State needed:** None

---

## The Real Question: What Layer Owns Resumability?

| Layer | What It Knows | Resumability Responsibility |
|-------|---------------|----------------------------|
| **Source system** (DB, Kafka, API) | Position/offset semantics | Often handles it natively |
| **Producer stage** | How to enumerate items | Knows how to seek/skip |
| **Framework** | Item flow between stages | Can track in-flight items |
| **Consumer stage** | Domain-specific completion | Knows when item is "done" |
| **Destination system** (DB, file, API) | Final state | Ultimate source of truth |

**Key insight:** Resumability is inherently a **source + destination** concern, not a pipeline concern.

---

## What Other Frameworks Do

### Apache Spark
- **Approach:** Checkpointing to HDFS/S3
- **Granularity:** RDD partition level
- **Opt-in:** `sparkContext.setCheckpointDir()`
- **Lesson:** Checkpointing is opt-in, storage is external

### Apache Flink
- **Approach:** Distributed snapshots (Chandy-Lamport)
- **Granularity:** Operator state + in-flight messages
- **Built-in:** Yes, but requires state backend config
- **Lesson:** Sophisticated but complex; overkill for batch

### Apache Beam
- **Approach:** Runner-dependent (Dataflow has checkpoints, Direct runner doesn't)
- **Lesson:** Abstraction delegates to execution engine

### Sidekiq
- **Approach:** Redis-based job queue with retry
- **Granularity:** Job level (not item level)
- **Lesson:** Simple model - jobs are atomic, retry whole job on failure

### Luigi / Airflow
- **Approach:** Task-level completion markers
- **Granularity:** Entire task (not individual items)
- **Lesson:** Coarse-grained "did this task run?" checkpointing

---

## Recommendation: Hybrid Approach

**Don't build full checkpointing into Minigun.** Instead:

### 1. Keep Producer Resumability User-Side

**Rationale:** Producers are inherently source-specific. A file producer, database producer, and Kafka producer all have different "resume" semantics. The user knows best.

**What we provide:**
- Documentation on patterns
- Examples for common sources (DB, Redis, files)

### 2. Add Optional In-Flight Tracking (Framework-Side)

**Rationale:** Tracking which items are currently being processed is generic and useful.

**Proposed API:**
```ruby
pipeline do
  # Enable in-flight tracking with pluggable backend
  track_items backend: :redis, redis: Redis.new

  producer :source do |output|
    # Producer emits items normally
    items.each { |item| output << item }
  end

  consumer :sink do |item|
    # Framework automatically tracks item lifecycle
    process(item)
    # On success: item marked complete
    # On failure: item available for retry
  end
end
```

### 3. Add Item Acknowledgment Callbacks (Framework-Side)

**Rationale:** Let consumers signal completion back to producers.

**Proposed API:**
```ruby
pipeline do
  producer :source do |output, ack_callback:|
    pending_items.each do |item|
      output << item
      # Called when item fully processed downstream
      ack_callback.on_complete(item) { mark_complete(item.id) }
    end
  end
end
```

### 4. Add Dead Letter Queue Support (Framework-Side)

**Rationale:** Failed items should go somewhere recoverable.

**Proposed API:**
```ruby
pipeline do
  dead_letter_queue :failures, backend: :redis

  processor :risky do |item, output|
    # On repeated failure, item goes to DLQ
    output << dangerous_operation(item)
  end
end
```

---

## What NOT to Build

1. **Full checkpoint serialization** - Too complex, storage-dependent
2. **Automatic producer resume** - Source-specific, user knows best
3. **Distributed snapshots** - Overkill for Ruby batch pipelines
4. **Transaction coordinator** - Use external systems (DB, Kafka)

---

## Implementation Priority

### Phase 1: Documentation (No Code)
- Expand production patterns guide
- Add examples for resumable producers
- Document idempotency patterns

### Phase 2: Item Lifecycle Hooks (Light Framework Support)
```ruby
# Optional callbacks, no persistence
on_item_complete { |item, stage| ... }
on_item_failed { |item, stage, error| ... }
```

### Phase 3: Pluggable Item Tracker (Optional Feature)
```ruby
# Opt-in tracking with user-provided backend
track_items backend: MyRedisTracker.new
```

### Phase 4: Dead Letter Queue (Optional Feature)
```ruby
# Opt-in DLQ for failed items
dead_letter_queue backend: MyDLQBackend.new
```

---

## Summary

| Concern | Recommendation | Rationale |
|---------|---------------|-----------|
| Producer resume position | **User-side** | Source-specific, user knows best |
| In-flight item tracking | **Optional framework** | Generic, useful, can abstract |
| Item completion acks | **Optional framework** | Enables user-side persistence |
| Dead letter queue | **Optional framework** | Generic failure handling |
| Full checkpointing | **User-side** | Too complex, storage-dependent |
| Idempotency | **User-side** | Domain-specific |

**Bottom line:** Minigun should provide **hooks and optional infrastructure** for resumability, but leave the **policy and persistence** to users. The framework handles item lifecycle; the user handles what that means for their data.

---

## Comparison to Error Handling Decision

This aligns with our error handling philosophy:

| Concern | Error Handling | Resumability |
|---------|---------------|--------------|
| Worker crashes | Framework (restart policies) | Framework (in-flight tracking) |
| Item failures | Framework (callbacks) + User (policy) | Framework (DLQ) + User (retry logic) |
| Job-level recovery | User (external orchestration) | User (producer resume logic) |
| State persistence | User (choose backend) | User (choose backend) |

**Consistent principle:** Framework provides mechanisms; users provide policy.
