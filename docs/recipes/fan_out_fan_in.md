# Recipe: Fan-Out / Fan-In

Split data to multiple parallel paths, then merge results back together.

## Problem

You need to process data through multiple transformations in parallel, then combine the results. For example: process an image through multiple filters, fetch data from multiple APIs, or validate using different rule sets.

## Solution

```ruby
require 'minigun'

class ParallelProcessor
  include Minigun::DSL

  attr_accessor :results

  def initialize
    @results = Concurrent::Array.new
    @mutex = Mutex.new
  end

  pipeline do
    # Single producer (fan-out source)
    producer :source, to: [:path_a, :path_b, :path_c] do |output|
      items.each { |item| output << item }
    end

    # Path A: Fast transformation
    processor :path_a, to: :merge, threads: 10 do |item, output|
      result = fast_transform(item)
      output << { path: :a, result: result, item_id: item[:id] }
    end

    # Path B: Slow transformation
    processor :path_b, to: :merge, threads: 5 do |item, output|
      result = slow_transform(item)
      output << { path: :b, result: result, item_id: item[:id] }
    end

    # Path C: External API call
    processor :path_c, to: :merge, threads: 20 do |item, output|
      result = fetch_from_api(item)
      output << { path: :c, result: result, item_id: item[:id] }
    end

    # Merge results (fan-in)
    processor :merge, from: [:path_a, :path_b, :path_c] do |partial_result, output|
      @mutex.synchronize do
        # Group results by item_id
        @grouped ||= Hash.new { |h, k| h[k] = {} }
        @grouped[partial_result[:item_id]][partial_result[:path]] = partial_result[:result]

        # When all paths complete for an item, emit combined result
        if @grouped[partial_result[:item_id]].size == 3
          combined = @grouped.delete(partial_result[:item_id])
          output << { item_id: partial_result[:item_id], combined: combined }
        end
      end
    end

    # Final processing
    consumer :finalize do |combined_result|
      results << combined_result
      process_combined(combined_result)
    end
  end

  private

  def items
    100.times.map { |i| { id: i, data: "item_#{i}" } }
  end

  def fast_transform(item)
    # Quick transformation
    item[:data].upcase
  end

  def slow_transform(item)
    # Expensive computation
    sleep 0.1
    item[:data].reverse
  end

  def fetch_from_api(item)
    # External API call
    HTTP.get("https://api.example.com/data/#{item[:id]}").parse
  rescue
    nil
  end

  def process_combined(result)
    # Do something with all three results
    Database.insert(result)
  end
end

# Run it
processor = ParallelProcessor.new
result = processor.run

puts "\n=== Parallel Processing Complete ==="
puts "Items processed: #{processor.results.size}"
puts "Duration: #{result[:duration].round(2)}s"
```

## How It Works

### Fan-Out

```ruby
producer :source, to: [:path_a, :path_b, :path_c] do |output|
  items.each { |item| output << item }
end
```

- Uses `to:` option with an array
- Each item sent to ALL three paths
- Paths process in parallel

### Parallel Paths

```ruby
processor :path_a, to: :merge, threads: 10 do |item, output|
  result = fast_transform(item)
  output << { path: :a, result: result, item_id: item[:id] }
end

processor :path_b, to: :merge, threads: 5 do |item, output|
  result = slow_transform(item)
  output << { path: :b, result: result, item_id: item[:id] }
end
```

- Each path runs independently
- Different thread counts based on workload
- All emit to the merge stage

### Fan-In (Merge)

```ruby
processor :merge, from: [:path_a, :path_b, :path_c] do |partial_result, output|
  @grouped ||= Hash.new { |h, k| h[k] = {} }
  @grouped[partial_result[:item_id]][partial_result[:path]] = partial_result[:result]

  # Wait for all paths to complete
  if @grouped[partial_result[:item_id]].size == 3
    combined = @grouped.delete(partial_result[:item_id])
    output << combined
  end
end
```

- Uses `from:` with array to receive from multiple sources
- Groups results by item ID
- Emits when all paths complete for an item

## Variations

### Diamond Pattern

```ruby
pipeline do
  producer :start do |output|
    output << initial_data
  end

  # Split
  processor :splitter, to: [:upper_path, :lower_path] do |data, output|
    output << data
  end

  # Upper path
  processor :upper_path, to: :joiner do |data, output|
    output << transform_upper(data)
  end

  # Lower path
  processor :lower_path, to: :joiner do |data, output|
    output << transform_lower(data)
  end

  # Join
  consumer :joiner, from: [:upper_path, :lower_path] do |result|
    process(result)
  end
end
```

### Async Fan-Out (Fire and Forget)

```ruby
producer :source, to: [:notify_email, :notify_sms, :notify_push] do |output|
  events.each { |event| output << event }
end

# No merge - each path is independent
consumer :notify_email do |event|
  send_email(event)
end

consumer :notify_sms do |event|
  send_sms(event)
end

consumer :notify_push do |event|
  send_push_notification(event)
end
```

### Conditional Fan-Out

```ruby
processor :conditional_split do |item, output|
  # Only route to applicable paths
  output.to(:path_a) << item if item[:needs_a]
  output.to(:path_b) << item if item[:needs_b]
  output.to(:path_c) << item if item[:needs_c]
end

processor :path_a, queues: [:path_a], to: :merge do |item, output|
  output << process_a(item)
end

processor :path_b, queues: [:path_b], to: :merge do |item, output|
  output << process_b(item)
end

processor :path_c, queues: [:path_c], to: :merge do |item, output|
  output << process_c(item)
end

# Merge receives variable number of results per item
processor :merge do |result, output|
  @results ||= Hash.new { |h, k| h[k] = [] }
  @results[result[:item_id]] << result

  # Emit when we've received all expected results
  if complete?(result[:item_id])
    output << @results.delete(result[:item_id])
  end
end
```

### Multi-Stage Fan-Out

```ruby
pipeline do
  producer :source, to: [:path_a, :path_b] do |output|
    # Initial fan-out
  end

  processor :path_a, to: [:subpath_a1, :subpath_a2] do |item, output|
    # Nested fan-out
    output << item
  end

  processor :subpath_a1, to: :merge_a do |item, output|
    output << transform_a1(item)
  end

  processor :subpath_a2, to: :merge_a do |item, output|
    output << transform_a2(item)
  end

  processor :merge_a, to: :final_merge do |result, output|
    # Merge path A results
    output << result
  end

  processor :path_b, to: :final_merge do |item, output|
    output << transform_b(item)
  end

  consumer :final_merge, from: [:merge_a, :path_b] do |result|
    # Final merge
  end
end
```

## Advanced Merging Strategies

### Time-Based Merge (Timeout)

```ruby
processor :timed_merge do |partial_result, output|
  @results ||= Hash.new { |h, k| h[k] = { data: {}, first_seen: Time.now } }

  item_id = partial_result[:item_id]
  @results[item_id][:data][partial_result[:path]] = partial_result[:result]

  # Emit if complete OR timed out
  if @results[item_id][:data].size == 3 ||
     (Time.now - @results[item_id][:first_seen]) > 5.0

    output << {
      item_id: item_id,
      results: @results.delete(item_id)[:data],
      complete: @results[item_id][:data].size == 3
    }
  end
end
```

### Majority Vote Merge

```ruby
processor :vote_merge do |partial_result, output|
  @votes ||= Hash.new { |h, k| h[k] = [] }
  @votes[partial_result[:item_id]] << partial_result[:result]

  votes = @votes[partial_result[:item_id]]

  # Wait for all votes
  if votes.size == 3
    # Find majority
    result = votes.group_by(&:itself).max_by { |_, v| v.size }[0]
    output << { item_id: partial_result[:item_id], result: result }
    @votes.delete(partial_result[:item_id])
  end
end
```

### First-Wins Merge

```ruby
processor :first_wins_merge do |partial_result, output|
  @seen ||= Concurrent::Set.new

  if @seen.add?(partial_result[:item_id])
    # First result wins, ignore others
    output << partial_result
  end
end
```

### Best-Result Merge

```ruby
processor :best_result_merge do |partial_result, output|
  @results ||= Hash.new { |h, k| h[k] = { data: {}, score: 0 } }

  item_id = partial_result[:item_id]
  @results[item_id][:data][partial_result[:path]] = partial_result[:result]

  # Track best result
  if partial_result[:score] > @results[item_id][:score]
    @results[item_id][:best] = partial_result[:result]
    @results[item_id][:score] = partial_result[:score]
  end

  # Emit when all paths complete
  if @results[item_id][:data].size == 3
    output << {
      item_id: item_id,
      best_result: @results[item_id][:best],
      all_results: @results.delete(item_id)[:data]
    }
  end
end
```

## Real-World Examples

### Image Processing Pipeline

```ruby
pipeline do
  producer :images, to: [:thumbnail, :watermark, :metadata] do |output|
    Dir['images/*.jpg'].each { |path| output << path }
  end

  processor :thumbnail, to: :merge, execution: :cow_fork, max: 4 do |path, output|
    thumbnail = ImageMagick.resize(path, '150x150')
    output << { path: path, type: :thumbnail, data: thumbnail }
  end

  processor :watermark, to: :merge, execution: :cow_fork, max: 4 do |path, output|
    watermarked = ImageMagick.watermark(path, logo)
    output << { path: path, type: :watermark, data: watermarked }
  end

  processor :metadata, to: :merge, threads: 10 do |path, output|
    exif = EXIFR::JPEG.new(path)
    output << { path: path, type: :metadata, data: exif.to_hash }
  end

  processor :merge, from: [:thumbnail, :watermark, :metadata] do |result, output|
    @images ||= Hash.new { |h, k| h[k] = {} }
    @images[result[:path]][result[:type]] = result[:data]

    if @images[result[:path]].size == 3
      output << { path: result[:path], data: @images.delete(result[:path]) }
    end
  end

  consumer :save do |image|
    save_processed_image(image)
  end
end
```

### Multi-API Data Enrichment

```ruby
pipeline do
  producer :users, to: [:profile_api, :payment_api, :activity_api] do |output|
    User.find_each { |user| output << user }
  end

  processor :profile_api, to: :merge, threads: 20 do |user, output|
    profile = ProfileAPI.fetch(user.id)
    output << { user_id: user.id, source: :profile, data: profile }
  end

  processor :payment_api, to: :merge, threads: 20 do |user, output|
    payment = PaymentAPI.fetch(user.id)
    output << { user_id: user.id, source: :payment, data: payment }
  end

  processor :activity_api, to: :merge, threads: 20 do |user, output|
    activity = ActivityAPI.fetch(user.id)
    output << { user_id: user.id, source: :activity, data: activity }
  end

  processor :merge, from: [:profile_api, :payment_api, :activity_api] do |result, output|
    @enriched ||= Hash.new { |h, k| h[k] = {} }
    @enriched[result[:user_id]][result[:source]] = result[:data]

    if @enriched[result[:user_id]].size == 3
      output << {
        user_id: result[:user_id],
        enriched_data: @enriched.delete(result[:user_id])
      }
    end
  end

  consumer :save do |enriched_user|
    EnrichedUser.create!(enriched_user)
  end
end
```

## Key Takeaways

- **Fan-out with `to:`** - Send to multiple stages with array
- **Fan-in with `from:`** - Receive from multiple stages
- **Track partial results** - Group by item ID in merge stage
- **Thread-safe merging** - Use Mutex or concurrent data structures
- **Different merge strategies** - Timeout, vote, first-wins, best-result
- **Optimize per path** - Different execution strategies for different workloads

## See Also

- [Routing Guide](../guides/04_routing.md) - Sequential, explicit, queue-based, and dynamic routing
- [Stages Guide](../guides/03_stages.md) - All stage types explained
- [Example: Diamond Pattern](../../examples/02_diamond_pattern.rb) - Working example
- [Example: Fan-Out Pattern](../../examples/03_fan_out_pattern.rb) - More examples
