# Monitoring with the HUD

Minigun includes a built-in **Heads-Up Display (HUD)** that shows real-time metrics for your pipeline. Let's learn how to use it to monitor and optimize your pipelines.

## What is the HUD?

The HUD is a terminal-based interface that displays:
- **Live throughput** for each stage
- **Latency percentiles** (P50, P99)
- **Bottleneck detection**
- **Animated flow diagram** showing data movement
- **Performance statistics table**

Think of it as `htop` for your Minigun pipelines.

## Quick Start

The easiest way to use the HUD:

```ruby
require 'minigun'
require 'minigun/hud'

class MyPipeline
  include Minigun::DSL

  pipeline do
    producer :generate do |output|
      loop do
        output << Time.now
        sleep 0.1
      end
    end

    processor :transform, threads: 5 do |time, output|
      sleep rand(0.01..0.05)
      output << time.to_i
    end

    consumer :print do |timestamp|
      puts timestamp
    end
  end
end

# Run with HUD - one line!
Minigun::HUD.run_with_hud(MyPipeline)
```

Press `q` to quit, or `h` for help.

## HUD Interface Overview

The HUD has three main areas:

```
┌─────────────────────────────────────────────────────────────┐
│ FLOW DIAGRAM (Left)        │  STATISTICS (Right)            │
│                             │                                │
│  ┌─────────────┐            │  STAGE      STATUS  ITEMS      │
│  │ ▶ generate  │            │  generate   ⚡      1234       │
│  └──── 15/s ───┘            │  transform  ⚡      1230       │
│         ⣿                   │  print      ⚡      1225       │
│  ┌─────────────┐            │                                │
│  │ ◆ transform │            │  Throughput: 15.2 items/s      │
│  └──── 15/s ───┘            │  Bottleneck: transform         │
│         ⣿                   │                                │
│  ┌─────────────┐            │                                │
│  │ ◀ print     │            │                                │
│  └─────────────┘            │                                │
└─────────────────────────────────────────────────────────────┘
│ Status: RUNNING │ Pipeline: MyPipeline │ [space] pause      │
└─────────────────────────────────────────────────────────────┘
```

### Flow Diagram (Left Panel)

Shows stages as boxes with animated connections:

- **Stage boxes** - Show name, type, and throughput
- **Animated connections** - Flowing characters show data movement
- **Color coding** - Green (active), yellow (bottleneck), red (error)

### Statistics Table (Right Panel)

Displays performance metrics:

| Column | Meaning |
|--------|---------|
| **STAGE** | Stage name with icon |
| **STATUS** | ⚡ active, ⏸ idle, ⚠ bottleneck, ✖ error |
| **ITEMS** | Total items processed |
| **THRU** | Throughput (items/second) |
| **P50** | Median latency |
| **P99** | 99th percentile latency |

### Status Bar (Bottom)

Shows pipeline status and keyboard shortcuts.

## Running the HUD

### Method 1: Automatic (Simplest)

```ruby
Minigun::HUD.run_with_hud(MyPipeline)
```

Automatically runs your pipeline and launches the HUD.

### Method 2: Interactive (Most Flexible)

```ruby
# Create and run in background
task = MyPipeline.new
task.run(background: true)

# Open HUD (blocks until you press 'q')
task.hud

# Task still running!
task.running?  # => true

# Can reopen HUD
task.hud

# Stop when done
task.stop
```

**Perfect for:**
- Development and debugging
- IRB/console sessions
- Exploring pipeline behavior

### Method 3: Manual (Advanced)

```ruby
task = MyPipeline.new
task.send(:_evaluate_pipeline_blocks!)
pipeline = task.instance_variable_get(:@_minigun_task).root_pipeline

hud = Minigun::HUD::Controller.new(pipeline)
hud_thread = Thread.new { hud.start }

task.run

hud.stop
hud_thread.join
```

## Keyboard Controls

| Key | Action |
|-----|--------|
| `q` | Quit HUD |
| `Space` | Pause/resume updates |
| `h` / `?` | Toggle help overlay |
| `r` | Force refresh |
| `↑` / `↓` | Scroll process list |
| `w` / `a` / `s` / `d` | Pan flow diagram |

## Reading the Metrics

### Throughput

**Items per second** processed by each stage:

```
generator:  50/s
transform:  25/s  ← BOTTLENECK
output:     25/s
```

The slowest stage limits overall throughput.

### Latency

**Time to process one item:**

- **P50 (Median)** - 50% of items process faster than this
- **P99** - 99% of items process faster than this

```
Stage      P50    P99
transform  10ms   45ms   ← Most items fast, some slow
output     2ms    5ms    ← Consistently fast
```

High P99 indicates **inconsistent performance**.

### Bottlenecks

The HUD highlights the **slowest stage** in yellow:

```
producer:   100/s
transform:  25/s   ⚠ BOTTLENECK
consumer:   100/s
```

To fix: **Add concurrency to the bottleneck**:

```ruby
processor :transform, threads: 10 do |item, output|
  # Now processes 250/s
end
```

## Practical Example: Optimizing a Pipeline

Let's use the HUD to find and fix performance issues:

### Step 1: Initial Pipeline

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

### Step 2: Check the HUD

The HUD shows:

```
STAGE       THRU    P50
fetch       ∞       0ms
api_call    10/s    100ms   ⚠ BOTTLENECK
transform   10/s    50ms
save        10/s    5ms
```

**Bottleneck:** `api_call` is the slowest stage at 10 items/s.

### Step 3: Add Concurrency

```ruby
processor :api_call, threads: 20 do |id, output|
  sleep 0.1
  output << fetch_user(id)
end
```

### Step 4: Check Again

```
STAGE       THRU    P50
fetch       ∞       0ms
api_call    200/s   100ms
transform   20/s    50ms    ⚠ BOTTLENECK
save        20/s    5ms
```

**New bottleneck:** `transform` is now the slowest.

### Step 5: Fix New Bottleneck

```ruby
processor :transform, threads: 10 do |user, output|
  sleep 0.05
  output << transform(user)
end
```

### Step 6: Final Check

```
STAGE       THRU    P50
fetch       ∞       0ms
api_call    200/s   100ms
transform   200/s   50ms
save        200/s   5ms
```

All stages balanced! Pipeline processes **200 items/second**.

## Color Coding

The HUD uses colors to communicate status:

### Stage Colors

- **Bright Green** - Active and processing
- **Yellow** - Bottleneck (slowest stage)
- **Red** - Errors detected
- **Gray** - Idle (waiting for input)

### Throughput Colors

- **Green** - High throughput
- **Yellow** - Moderate throughput
- **Red** - Low throughput

## HUD with Background Tasks

Run long-lived pipelines and monitor them:

```ruby
# Start pipeline in background
task = MyLongRunningPipeline.new
task.run(background: true)
puts "Pipeline started (PID: #{Process.pid})"

# Do other work...
sleep 10

# Check on it
task.hud  # Opens HUD

# Close HUD (pipeline keeps running)
# Press 'q'

# Do more work...

# Check again later
task.hud

# Stop when done
task.stop
```

## HUD in Production?

The HUD is primarily for **development and debugging**:

✅ **Use HUD for:**
- Development
- Testing
- Debugging performance issues
- Understanding pipeline behavior
- Demos and presentations

❌ **Don't use HUD for:**
- Production deployments
- CI/CD pipelines
- Background jobs
- Headless environments

For production monitoring, use the stats API instead:

```ruby
task = MyPipeline.new
result = task.run

stats = task.root_pipeline.stats
puts "Throughput: #{stats.throughput} items/s"
puts "Bottleneck: #{stats.bottleneck.stage_name}"
```

## Troubleshooting

### "No TTY" Error

The HUD requires a terminal. If you see this error:

```ruby
# Run without HUD in non-TTY environments
task.run  # Normal run without HUD
```

### Garbled Output

Ensure your terminal supports ANSI and UTF-8:

```bash
export TERM=xterm-256color
export LANG=en_US.UTF-8
```

### Performance Impact

The HUD adds ~1-2% CPU overhead. Disable for maximum performance:

```ruby
# Production: No HUD
task.run

# Development: With HUD
Minigun::HUD.run_with_hud(MyTask)
```

## Key Takeaways

- The HUD provides **real-time monitoring** of your pipeline
- Use it to **identify bottlenecks** and optimize
- Three ways to launch: automatic, interactive, or manual
- **Bottlenecks** are highlighted in yellow
- Use **keyboard controls** to navigate and control
- Perfect for development, not for production

## Congratulations!

You've completed the Tour of Minigun! You now understand:

1. ✅ What Minigun is and when to use it
2. ✅ Building pipelines with stages
3. ✅ Different stage types (producer, processor, consumer)
4. ✅ Routing strategies (sequential, fan-out, fan-in, dynamic)
5. ✅ Adding concurrency with threads
6. ✅ Choosing execution strategies (inline, thread, cow, ipc)
7. ✅ Monitoring with the HUD

## What's Next?

### Explore Recipes

Jump to practical examples:
- [ETL Pipeline](../recipes/etl_pipeline.md)
- [Web Crawler](../recipes/web_crawler.md)
- [Batch Processing](../recipes/batch_processing.md)

### Read the Guides

Deep dive into specific topics:
- [Stages Guide](03_stages.md) - All stage types explained
- [Routing Guide](04_routing.md) - Sequential, explicit, queue-based, and dynamic routing
- [Performance Tuning](11_performance_tuning.md) - Optimization strategies

### Browse Examples

Check out the [examples directory](../../examples/) with 100+ working examples.

---

**Ready for more?** [Browse the Documentation →](../index.md)
