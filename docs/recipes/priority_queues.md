# Recipe: Priority Queues

Route items by priority for differentiated processing.

## Problem

You have items with different priorities (urgent, normal, low). High-priority items need immediate processing with more resources, while low-priority items can wait.

## Solution

```ruby
require 'minigun'

class PriorityProcessor
  include Minigun::DSL

  attr_accessor :high_count, :normal_count, :low_count

  def initialize
    @high_count = Concurrent::AtomicFixnum.new(0)
    @normal_count = Concurrent::AtomicFixnum.new(0)
    @low_count = Concurrent::AtomicFixnum.new(0)
  end

  pipeline do
    # Generate mixed-priority items
    producer :generate do |output|
      items.each do |item|
        output << item
      end
    end

    # Route by priority using queues
    processor :route_by_priority do |item, output|
      case item[:priority]
      when :high
        output.to(:high_priority) << item
      when :normal
        output.to(:normal_priority) << item
      when :low
        output.to(:low_priority) << item
      else
        output.to(:normal_priority) << item  # Default
      end
    end

    # High priority: Maximum resources
    processor :high_handler,
              queues: [:high_priority],
              threads: 20,
              queue_size: 100 do |item, output|

      # Process immediately with high concurrency
      result = process_urgently(item)
      @high_count.increment
      output << { priority: :high, result: result, processed_at: Time.now }
    end

    # Normal priority: Balanced resources
    processor :normal_handler,
              queues: [:normal_priority],
              threads: 10,
              queue_size: 500 do |item, output|

      result = process_normally(item)
      @normal_count.increment
      output << { priority: :normal, result: result, processed_at: Time.now }
    end

    # Low priority: Minimal resources
    processor :low_handler,
              queues: [:low_priority],
              threads: 2,
              queue_size: 5000 do |item, output|

      result = process_when_available(item)
      @low_count.increment
      output << { priority: :low, result: result, processed_at: Time.now }
    end

    # Collect all results
    consumer :collect, from: [:high_handler, :normal_handler, :low_handler] do |result|
      save_result(result)
    end
  end

  private

  def items
    # Mix of priorities
    [
      { id: 1, priority: :high, data: 'urgent task' },
      { id: 2, priority: :normal, data: 'regular task' },
      { id: 3, priority: :high, data: 'another urgent' },
      { id: 4, priority: :low, data: 'background task' },
      # ... more items
    ]
  end

  def process_urgently(item)
    # Fast processing for high priority
    transform(item[:data])
  end

  def process_normally(item)
    # Standard processing
    transform(item[:data])
  end

  def process_when_available(item)
    # Can be slower for low priority
    transform(item[:data])
  end

  def save_result(result)
    # Store result
    Database.insert(result)
  end
end

# Run it
processor = PriorityProcessor.new
result = processor.run

puts "\n=== Processing Complete ==="
puts "High priority: #{processor.high_count.value}"
puts "Normal priority: #{processor.normal_count.value}"
puts "Low priority: #{processor.low_count.value}"
```

## How It Works

### Routing to Named Queues

```ruby
processor :route_by_priority do |item, output|
  case item[:priority]
  when :high
    output.to(:high_priority) << item
  when :normal
    output.to(:normal_priority) << item
  when :low
    output.to(:low_priority) << item
  end
end
```

- Uses `output.to(:queue_name)` for dynamic routing
- Each priority gets its own queue
- Router makes decisions at runtime

### Priority-Specific Handlers

```ruby
# High priority: More resources
processor :high_handler,
          queues: [:high_priority],
          threads: 20,
          queue_size: 100 do |item, output|
  # 20 threads, small queue (fast processing)
end

# Low priority: Fewer resources
processor :low_handler,
          queues: [:low_priority],
          threads: 2,
          queue_size: 5000 do |item, output|
  # 2 threads, large queue (can buffer)
end
```

- Each handler subscribes to its queue with `queues:` option
- Different thread counts for different priorities
- Different queue sizes for buffering

## Variations

### Multi-Level Priorities

```ruby
processor :route do |item, output|
  priority = calculate_priority(item)

  case priority
  when 0..20
    output.to(:critical) << item
  when 21..50
    output.to(:high) << item
  when 51..80
    output.to(:normal) << item
  else
    output.to(:low) << item
  end
end
```

### Priority + Type Routing

```ruby
processor :route_by_priority_and_type do |item, output|
  queue_name = "#{item[:type]}_#{item[:priority]}"
  output.to(queue_name) << item
end

# Handlers for each combination
processor :email_high, queues: [:email_high], threads: 10 do |item, output|
  send_email_urgently(item)
end

processor :email_normal, queues: [:email_normal], threads: 5 do |item, output|
  send_email_normally(item)
end

processor :sms_high, queues: [:sms_high], threads: 15 do |item, output|
  send_sms_urgently(item)
end

processor :sms_normal, queues: [:sms_normal], threads: 3 do |item, output|
  send_sms_normally(item)
end
```

### Dynamic Priority Assignment

```ruby
processor :calculate_priority do |item, output|
  priority = case
    when item[:user_type] == 'premium'
      :high
    when item[:age] > 24.hours
      :high  # Old items become urgent
    when item[:retries] > 3
      :low   # Failed items deprioritized
    else
      :normal
    end

  output.to("#{priority}_priority") << item.merge(priority: priority)
end
```

### SLA-Based Routing

```ruby
processor :sla_router do |item, output|
  time_remaining = item[:deadline] - Time.now

  queue = if time_remaining < 5.minutes
    :urgent        # About to miss deadline
  elsif time_remaining < 1.hour
    :high
  elsif time_remaining < 1.day
    :normal
  else
    :low
  end

  output.to(queue) << item
end
```

## Priority Inversion Prevention

### Timeout Low Priority

```ruby
processor :low_handler,
          queues: [:low_priority],
          threads: 2 do |item, output|

  # Promote to high priority if waiting too long
  if item[:queued_at] && (Time.now - item[:queued_at]) > 1.hour
    logger.warn("Low priority item #{item[:id]} waited too long, promoting")
    output.to(:high_priority) << item
    next
  end

  process_when_available(item)
end
```

### Age-Based Promotion

```ruby
processor :age_checker do |item, output|
  age = Time.now - item[:created_at]

  promoted_priority = case item[:priority]
  when :low
    age > 2.hours ? :normal : :low
  when :normal
    age > 1.hour ? :high : :normal
  else
    item[:priority]
  end

  if promoted_priority != item[:priority]
    logger.info("Promoting #{item[:id]} from #{item[:priority]} to #{promoted_priority}")
    item[:priority] = promoted_priority
  end

  output.to("#{promoted_priority}_priority") << item
end
```

## Resource Management

### Weighted Fair Queuing

```ruby
processor :weighted_router do |item, output|
  @round_robin_counter ||= 0
  @round_robin_counter += 1

  # Distribution: 50% high, 30% normal, 20% low
  queue = case @round_robin_counter % 10
  when 0..4  # 50%
    :high_priority
  when 5..7  # 30%
    :normal_priority
  else       # 20%
    :low_priority
  end

  output.to(queue) << item
end
```

### CPU Quotas

```ruby
processor :high_handler, threads: 10 do |item, output|
  # Limit CPU time for each item
  Timeout.timeout(5.seconds) do
    result = process_urgently(item)
    output << result
  end
rescue Timeout::Error
  logger.error("High priority item #{item[:id]} exceeded CPU quota")
  # Downgrade to normal priority
  output.to(:normal_priority) << item
end
```

## Monitoring

### Priority-Specific Metrics

```ruby
def report_stats
  total = @high_count.value + @normal_count.value + @low_count.value

  puts "\n=== Priority Distribution ==="
  puts "High:   #{@high_count.value.to_s.rjust(6)} (#{percent(@high_count.value, total)}%)"
  puts "Normal: #{@normal_count.value.to_s.rjust(6)} (#{percent(@normal_count.value, total)}%)"
  puts "Low:    #{@low_count.value.to_s.rjust(6)} (#{percent(@low_count.value, total)}%)"
  puts "Total:  #{total.to_s.rjust(6)}"
end

def percent(count, total)
  return 0 if total.zero?
  ((count.to_f / total) * 100).round(1)
end
```

### Queue Depth Monitoring

```ruby
processor :monitor_queue_depth do |item, output|
  @queue_depths ||= Concurrent::Hash.new(0)

  # Track current queue sizes
  [:high_priority, :normal_priority, :low_priority].each do |queue|
    depth = get_queue_depth(queue)
    @queue_depths[queue] = depth

    if depth > threshold_for(queue)
      logger.warn("Queue #{queue} depth at #{depth}")
    end
  end

  output << item
end

def threshold_for(queue)
  case queue
  when :high_priority then 50    # Alert if high priority backs up
  when :normal_priority then 500
  when :low_priority then 5000
  end
end
```

## Advanced Patterns

### Priority Inheritance

```ruby
processor :inherit_priority do |item, output|
  # Child tasks inherit parent priority
  if item[:parent_id]
    parent = find_parent(item[:parent_id])
    item[:priority] = [item[:priority], parent[:priority]].max
  end

  output.to("#{item[:priority]}_priority") << item
end
```

### Deadline-Based Scheduling

```ruby
producer :deadline_scheduler do |output|
  loop do
    # Fetch items closest to deadline
    items = DeadlineQueue.pop_until_deadline(Time.now + 5.minutes)

    items.each do |item|
      priority = if item[:deadline] < Time.now + 5.minutes
        :critical
      elsif item[:deadline] < Time.now + 1.hour
        :high
      else
        :normal
      end

      output.to("#{priority}_priority") << item
    end

    sleep 1
  end
end
```

### Load Shedding

```ruby
processor :load_shedder do |item, output|
  @current_load ||= Concurrent::AtomicFixnum.new(0)
  load = @current_load.value

  # Drop low priority under high load
  if load > 1000 && item[:priority] == :low
    logger.warn("Shedding low priority item #{item[:id]} due to high load")
    @dropped_count.increment
    next
  end

  # Drop normal priority under very high load
  if load > 5000 && item[:priority] == :normal
    logger.warn("Shedding normal priority item #{item[:id]} due to very high load")
    @dropped_count.increment
    next
  end

  output << item
end
```

## Testing

### Test Priority Distribution

```ruby
RSpec.describe PriorityProcessor do
  it 'routes items by priority' do
    processor = PriorityProcessor.new

    # Create test items
    high_items = 10.times.map { |i| { id: i, priority: :high } }
    normal_items = 20.times.map { |i| { id: i + 10, priority: :normal } }

    allow(processor).to receive(:items).and_return(high_items + normal_items)

    processor.run

    expect(processor.high_count.value).to eq(10)
    expect(processor.normal_count.value).to eq(20)
  end
end
```

### Test Priority Promotion

```ruby
it 'promotes old items' do
  old_item = { id: 1, priority: :low, created_at: 3.hours.ago }

  # Should be promoted to normal
  result = processor.calculate_priority(old_item)

  expect(result[:priority]).to eq(:normal)
end
```

## Key Takeaways

- **Route to named queues** with `output.to(:queue_name)`
- **Subscribe with `queues:`** option to receive from specific queues
- **Different resources** for different priorities (threads, queue size)
- **Monitor queue depths** to detect backups
- **Prevent priority inversion** with timeouts and promotions
- **Load shedding** under extreme load

## See Also

- [Routing Guide](../guides/04_routing.md) - Sequential, explicit, queue-based, and dynamic routing
- [Stages Guide](../guides/03_stages.md) - All stage types explained
- [Example: Priority Routing](../../examples/40_priority_routing.rb) - Working example
