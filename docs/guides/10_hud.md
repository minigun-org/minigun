# HUD: Real-Time Monitoring

The Minigun HUD (Heads-Up Display) is a terminal-based interface for monitoring your pipelines in real-time. Think of it as `htop` for your data pipelines.

![HUD Screenshot](screenshot.png)

## Features

- **Real-time metrics** - Live throughput, latency, and item counts
- **Animated flow diagram** - See data flowing through your pipeline
- **Performance table** - Per-stage statistics with P50/P99 latency
- **Bottleneck detection** - Automatically identifies slowest stages
- **Keyboard controls** - Interactive navigation and control
- **Zero dependencies** - Pure Ruby with ANSI terminal control

## Quick Start

The simplest way to use the HUD:

```ruby
require 'minigun'
require 'minigun/hud'

class MyPipeline
  include Minigun::DSL

  pipeline do
    producer :generate do |output|
      1000.times { |i| output << i }
    end

    processor :transform, threads: 5 do |number, output|
      sleep 0.01  # Simulate work
      output << (number * 2)
    end

    consumer :save do |result|
      database.insert(result)
    end
  end
end

# One line to run with HUD
Minigun::HUD.run_with_hud(MyPipeline)
```

That's it! The HUD opens automatically and shows your pipeline running.

## The Interface

The HUD has three main areas:

```
┌─────────────────────────────────────────────────────────────┐
│ FLOW DIAGRAM (Left)        │  STATISTICS (Right)            │
│                             │                                │
│  ┌─────────────┐            │  STAGE      STATUS  ITEMS  THRU│
│  │ ▶ generate  │            │  generate   ⚡      1234   100/s│
│  └──── 100/s ──┘            │  transform  ⚠       1230    50/s│
│         ⣿                   │  save       ⚡      1225   100/s│
│  ┌─────────────┐            │                                │
│  │ ◆ transform │            │  P50: 10ms  P99: 45ms          │
│  └──── 50/s ───┘            │  Bottleneck: transform         │
│         ⣿                   │                                │
│  ┌─────────────┐            │                                │
│  │ ◀ save      │            │                                │
│  └─────────────┘            │                                │
└─────────────────────────────────────────────────────────────┘
│ Status: RUNNING │ Pipeline: MyPipeline │ [q] quit [?] help │
└─────────────────────────────────────────────────────────────┘
```

### Flow Diagram (Left Panel)

Shows your pipeline stages as boxes with animated connections:

- **Stage boxes** show name, type icon, and current throughput
- **Flowing animations** show data moving between stages
- **Color coding** indicates status:
  - **Green** - Active and processing
  - **Yellow** - Bottleneck (slowest stage)
  - **Red** - Errors detected
  - **Gray** - Idle (waiting for input)

**Stage Icons:**
- `▶` Producer (generates data)
- `◆` Processor (transforms data)
- `◀` Consumer (consumes data)
- `⊞` Accumulator (batches items)
- `◇` Router (distributes to multiple stages)
- `⑂` Fork (IPC/COW process)

**Status Indicators:**
- `⚡` Active (currently processing)
- `⏸` Idle (waiting for work)
- `⚠` Bottleneck (slowest stage)
- `✖` Error (failures detected)
- `✓` Done (completed)

### Statistics Table (Right Panel)

Displays real-time performance metrics:

| Column | Description |
|--------|-------------|
| **STAGE** | Stage name with type icon |
| **STATUS** | Current status indicator |
| **ITEMS** | Total items processed |
| **THRU** | Throughput (items/second) |
| **P50** | Median latency (50th percentile) |
| **P99** | 99th percentile latency |

### Status Bar (Bottom)

Shows:
- **Pipeline status** - RUNNING, PAUSED, or FINISHED
- **Pipeline name** - Current pipeline being monitored
- **Keyboard hints** - Available controls

## Using the HUD

### Method 1: Automatic (Simplest)

```ruby
require 'minigun/hud'

Minigun::HUD.run_with_hud(MyPipeline)
```

Automatically runs your pipeline and launches the HUD. Blocks until the pipeline finishes or you press `q`.

**When the pipeline completes:**
- HUD stays open to show final statistics
- Press `q` to exit and see results
- Review throughput, latency, and bottlenecks

### Method 2: Interactive (Most Flexible)

```ruby
# Run in background
task = MyPipeline.new
task.run(background: true)
puts "Pipeline started in background"

# Open HUD (blocks until you press 'q')
task.hud

# Task still running!
task.running?  # => true

# Can reopen HUD anytime
task.hud

# Stop when done
task.stop
```

**Perfect for:**
- Development and debugging
- IRB/console sessions
- Long-running pipelines
- Checking on background tasks

### Method 3: Manual (Advanced)

```ruby
task = MyPipeline.new
task.send(:_evaluate_pipeline_blocks!)
pipeline = task.instance_variable_get(:@_minigun_task).root_pipeline

# Start HUD in background thread
hud = Minigun::HUD::Controller.new(pipeline)
hud_thread = Thread.new { hud.start }

# Run your pipeline
task.run

# Stop HUD
hud.stop
hud_thread.join
```

## Keyboard Controls

| Key | Action |
|-----|--------|
| `q` / `Q` | Quit HUD |
| `Space` | Pause/resume updates |
| `h` / `H` / `?` | Toggle help overlay |
| `r` / `R` | Force refresh |
| `↑` / `↓` | Scroll process list |
| `w` / `a` / `s` / `d` | Pan flow diagram |

**Note:** Some controls are disabled when the pipeline finishes.

## Reading the Metrics

### Throughput

**Items per second** processed by each stage.

```
generator:  100/s
transform:   50/s  ← BOTTLENECK
output:      50/s
```

The slowest stage limits overall pipeline throughput.

**To fix:** Add more threads or processes to the bottleneck:

```ruby
processor :transform, threads: 20 do |item, output|
  # Increased from 5 to 20 threads
end
```

### Latency

**Time to process one item:**

- **P50 (Median)** - Half of items process faster than this
- **P99** - 99% of items process faster than this

```
Stage      P50    P99
transform  10ms   45ms   ← Mostly fast, some slow
output     2ms    5ms    ← Consistently fast
```

**High P99 indicates:**
- Inconsistent performance
- Occasional slow operations
- Resource contention

### Bottlenecks

The HUD highlights the **slowest stage** in yellow with a `⚠` indicator.

**Common causes:**
- Not enough concurrency (add threads/processes)
- Slow external dependencies (API, database)
- CPU-intensive work (use fork instead of threads)
- Large queue backlog (upstream too fast)

## Example: Optimizing a Pipeline

Let's use the HUD to find and fix performance issues.

### Initial Pipeline

```ruby
class DataProcessor
  include Minigun::DSL

  pipeline do
    producer :fetch do |output|
      1000.times { |i| output << i }
    end

    processor :api_call do |id, output|
      sleep 0.1  # Simulates API call
      output << fetch_user(id)
    end

    processor :transform do |user, output|
      sleep 0.05
      output << transform(user)
    end

    consumer :save do |user|
      database.insert(user)
    end
  end
end

Minigun::HUD.run_with_hud(DataProcessor)
```

### What the HUD Shows

```
STAGE       THRU    P50
fetch       ∞       0ms
api_call    10/s    100ms   ⚠ BOTTLENECK
transform   10/s    50ms
save        10/s    5ms
```

**Bottleneck:** `api_call` at only 10 items/s.

### Fix: Add Concurrency

```ruby
processor :api_call, threads: 20 do |id, output|
  sleep 0.1
  output << fetch_user(id)
end
```

### Check the HUD Again

```
STAGE       THRU    P50
fetch       ∞       0ms
api_call    200/s   100ms
transform   20/s    50ms    ⚠ BOTTLENECK
save        20/s    5ms
```

**New bottleneck:** `transform` at 20 items/s.

### Fix Again

```ruby
processor :transform, threads: 10 do |user, output|
  sleep 0.05
  output << transform(user)
end
```

### Final Result

```
STAGE       THRU    P50
fetch       ∞       0ms
api_call    200/s   100ms
transform   200/s   50ms
save        200/s   5ms
```

All stages balanced! Pipeline now processes **200 items/second** (20x improvement).

## When to Use the HUD

### ✅ Use HUD For:

- **Development** - Understanding pipeline behavior
- **Debugging** - Finding performance issues
- **Testing** - Verifying optimizations work
- **Demos** - Showing pipeline execution
- **Learning** - Seeing data flow in real-time

### ❌ Don't Use HUD For:

- **Production** - No terminal in production
- **CI/CD** - No TTY in automated environments
- **Background jobs** - Run headless instead
- **Long-running daemons** - Use logging instead

For production monitoring, use the Stats API:

```ruby
task = MyPipeline.new
result = task.run

stats = task.root_pipeline.stats
puts "Throughput: #{stats.throughput} items/s"
puts "Bottleneck: #{stats.bottleneck.stage_name}"
```

## Troubleshooting

### "No TTY" Error

The HUD requires a terminal. If running in a non-interactive environment:

```ruby
# Skip HUD in non-TTY environments
if $stdin.tty?
  Minigun::HUD.run_with_hud(MyPipeline)
else
  MyPipeline.new.run
end
```

### Garbled Output

Ensure your terminal supports ANSI escape sequences and UTF-8:

```bash
export TERM=xterm-256color
export LANG=en_US.UTF-8
```

### Performance Impact

The HUD adds ~1-2% CPU overhead. To disable:

```ruby
# Production: No HUD
task.run

# Development: With HUD
Minigun::HUD.run_with_hud(MyTask)
```

### Large Pipelines

For complex pipelines with many stages, use the pan controls:

- `w` / `a` / `s` / `d` - Pan the flow diagram
- `↑` / `↓` - Scroll the statistics table

## Next Steps

- [Quick Start Guide](quick_start.md) - Get started in 60 seconds
- [Interface Guide](interface.md) - Detailed UI walkthrough
- [Metrics Guide](metrics.md) - Understanding the data
- [HUD API](advanced.md) - Programmatic control

---

**Ready to monitor?** [Quick Start →](quick_start.md)
