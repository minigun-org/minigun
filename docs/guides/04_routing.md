# Routing

Routing determines how data flows between stages. Minigun supports multiple routing strategies, from simple sequential connections to complex dynamic routing.

## Sequential Routing (Default)

By default, stages connect **sequentially** in the order they're defined:

```ruby
pipeline do
  producer :a do |output|
    output << 1
  end

  processor :b do |item, output|
    output << item * 2
  end

  consumer :c do |item|
    puts item
  end
end

# Data flows: a → b → c
```

This is the simplest routing model—perfect for linear pipelines.

## Explicit Routing

Use `from:` and `to:` options to explicitly define connections:

### Using `to:`

```ruby
pipeline do
  producer :source, to: :destination do |output|
    output << "data"
  end

  consumer :destination do |item|
    puts item
  end
end
```

### Using `from:`

```ruby
pipeline do
  producer :source do |output|
    output << "data"
  end

  consumer :destination, from: :source do |item|
    puts item
  end
end
```

### Both Together

```ruby
processor :middle, from: :source, to: :sink do |item, output|
  output << item
end
```

## Fan-Out (Broadcasting)

Send data from one stage to **multiple** downstream stages:

```ruby
pipeline do
  producer :source, to: [:stage_a, :stage_b, :stage_c] do |output|
    output << "data"
  end

  consumer :stage_a do |item|
    puts "A received: #{item}"
  end

  consumer :stage_b do |item|
    puts "B received: #{item}"
  end

  consumer :stage_c do |item|
    puts "C received: #{item}"
  end
end

# Each item goes to ALL three consumers
```

### Practical Example: Multiple Outputs

```ruby
pipeline do
  producer :fetch_users, to: [:cache, :process] do |output|
    User.find_each { |user| output << user }
  end

  # Cache users for quick lookup
  consumer :cache do |user|
    Rails.cache.write("user:#{user.id}", user)
  end

  # Also process users
  processor :process do |user, output|
    output << transform(user)
  end
end
```

## Fan-In (Merging)

Multiple stages can feed into **one** downstream stage:

```ruby
pipeline do
  producer :source_a, to: :merge do |output|
    output << "from A"
  end

  producer :source_b, to: :merge do |output|
    output << "from B"
  end

  consumer :merge, from: [:source_a, :source_b] do |item|
    puts "Received: #{item}"
  end
end

# merge receives items from both producers
```

### Practical Example: Multiple Data Sources

```ruby
pipeline do
  producer :database, to: :process do |output|
    Database.find_each { |record| output << record }
  end

  producer :api, to: :process do |output|
    API.fetch_all.each { |record| output << record }
  end

  producer :files, to: :process do |output|
    Dir['data/*.json'].each do |file|
      JSON.parse(File.read(file)).each { |record| output << record }
    end
  end

  processor :process, from: [:database, :api, :files] do |record, output|
    output << normalize(record)
  end
end
```

## Diamond Pattern

Combine fan-out and fan-in to create parallel processing paths:

```ruby
pipeline do
  # One source splits to two processors
  producer :source, to: [:path_a, :path_b] do |output|
    5.times { |i| output << i }
  end

  # Path A: multiply by 2
  processor :path_a, to: :merge do |num, output|
    output << num * 2
  end

  # Path B: multiply by 3
  processor :path_b, to: :merge do |num, output|
    output << num * 3
  end

  # Merge results
  consumer :merge, from: [:path_a, :path_b] do |num|
    puts "Result: #{num}"
  end
end

# Output:
# Result: 0  (0 * 2)
# Result: 0  (0 * 3)
# Result: 2  (1 * 2)
# Result: 3  (1 * 3)
# ...
```

## Queue-Based Routing

Route items to **named queues** instead of specific stages:

```ruby
pipeline do
  producer :classify do |output|
    items.each do |item|
      if item.priority == :high
        output.to(:high_priority) << item
      else
        output.to(:low_priority) << item
      end
    end
  end

  # Subscribe to high priority queue
  processor :urgent, queues: [:high_priority] do |item, output|
    handle_urgent(item)
  end

  # Subscribe to low priority queue
  processor :normal, queues: [:low_priority] do |item, output|
    handle_normal(item)
  end
end
```

### Multiple Queue Subscriptions

A stage can subscribe to multiple queues:

```ruby
processor :handler, queues: [:high_priority, :medium_priority, :default] do |item, output|
  # Receives items from all three queues
end
```

## Dynamic Routing

Make routing decisions at **runtime** based on data:

```ruby
pipeline do
  producer :source, to: [:router] do |output|
    users.each { |user| output << user }
  end

  processor :router, to: [:vip, :regular] do |user, output|
    if user.vip?
      output.to(:vip) << user
    else
      output.to(:regular) << user
    end
  end

  consumer :vip do |user|
    send_to_vip_handler(user)
  end

  consumer :regular do |user|
    send_to_regular_handler(user)
  end
end
```

### Complex Routing Logic

```ruby
processor :route_by_type, to: [:emails, :sms, :push, :error] do |notification, output|
  case notification.type
  when :email
    output.to(:emails) << notification
  when :sms
    output.to(:sms) << notification
  when :push
    output.to(:push) << notification
  else
    output.to(:error) << notification
  end
end
```

## Practical Example: Message Router

Here's a complete example routing messages by type and priority:

```ruby
class MessageRouter
  include Minigun::DSL

  pipeline do
    # Generate mixed messages
    producer :messages do |output|
      [
        { type: :email, priority: :high, content: "Urgent email" },
        { type: :sms, priority: :low, content: "SMS reminder" },
        { type: :email, priority: :low, content: "Newsletter" },
        { type: :push, priority: :high, content: "Alert!" }
      ].each { |msg| output << msg }
    end

    # Route by type
    processor :route_by_type, to: [:email_handler, :sms_handler, :push_handler] do |msg, output|
      case msg[:type]
      when :email
        output.to(:email_handler) << msg
      when :sms
        output.to(:sms_handler) << msg
      when :push
        output.to(:push_handler) << msg
      end
    end

    # Each handler routes by priority
    processor :email_handler, to: [:urgent, :normal] do |msg, output|
      if msg[:priority] == :high
        output.to(:urgent) << msg
      else
        output.to(:normal) << msg
      end
    end

    processor :sms_handler, to: [:urgent, :normal] do |msg, output|
      if msg[:priority] == :high
        output.to(:urgent) << msg
      else
        output.to(:normal) << msg
      end
    end

    processor :push_handler, to: [:urgent, :normal] do |msg, output|
      if msg[:priority] == :high
        output.to(:urgent) << msg
      else
        output.to(:normal) << msg
      end
    end

    # Priority-based processing
    consumer :urgent, threads: 10 do |msg|
      send_immediately(msg)
    end

    consumer :normal, threads: 2 do |msg|
      queue_for_batch_send(msg)
    end
  end
end
```

## Routing Best Practices

### 1. Keep It Simple
Start with sequential routing. Only add complexity when needed.

```ruby
# Good: Simple and clear
producer :a do |output| ... end
processor :b do |item, output| ... end
consumer :c do |item| ... end
```

### 2. Use Explicit Routing for Complex Graphs
When the flow isn't linear, make connections explicit:

```ruby
# Good: Clear connections
producer :source, to: [:transform_a, :transform_b] do ... end
processor :transform_a, to: :merge do ... end
processor :transform_b, to: :merge do ... end
consumer :merge, from: [:transform_a, :transform_b] do ... end
```

### 3. Validate Your Routing
Minigun validates your routing graph and will error on:
- Cycles (infinite loops)
- Disconnected stages
- Missing stage references

### 4. Document Complex Routing
Add comments for non-obvious routing:

```ruby
# Route by account type:
#   - Free users → slow lane (2 threads)
#   - Paid users → fast lane (10 threads)
processor :route_by_account do |user, output|
  # ...
end
```

## Routing Patterns Summary

| Pattern | Use Case | Example |
|---------|----------|---------|
| **Sequential** | Simple linear flow | A → B → C |
| **Fan-out** | Broadcast to multiple stages | A → [B, C, D] |
| **Fan-in** | Merge multiple sources | [A, B] → C |
| **Diamond** | Parallel paths with merge | A → [B, C] → D |
| **Queue-based** | Priority lanes | Route by priority queue |
| **Dynamic** | Runtime decisions | Route based on data |

## Key Takeaways

- **Sequential routing** is the default (stages in definition order)
- **Explicit routing** uses `from:` and `to:` options
- **Fan-out** sends one item to multiple stages
- **Fan-in** receives items from multiple stages
- **Queue-based routing** routes to named queues
- **Dynamic routing** makes decisions at runtime with `output.to()`

## What's Next?

Now that you understand routing, let's add parallelism with concurrency.

→ [**Continue to Concurrency**](05_concurrency.md)

---

**See Also:**
- [Execution Strategies](06_execution_strategies.md) - Combine routing with parallel execution
- [Example: Diamond Pattern](../../examples/02_diamond_pattern.rb) - Working example
- [Example: Complex Routing](../../examples/04_complex_routing.rb) - Advanced patterns
