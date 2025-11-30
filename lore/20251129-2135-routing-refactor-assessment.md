# Routing Strategies Refactor Assessment

## Summary

The recent routing strategies implementation (RouterDemandStage, RouterPartitionStage) introduced code duplication across all four router classes. This assessment identifies opportunities for DRYing up the code.

## Issues Found

### 1. Duplicated run_stage Logic (HIGH - Slam Dunk)

All four router classes have nearly identical `run_stage` methods:
- `RouterBroadcastStage`
- `RouterRoundRobinStage`
- `RouterDemandStage`
- `RouterPartitionStage`

Each duplicates:
1. **EndOfSource handling** (~7 lines, identical in all 4)
2. **RoutedItem handling** (~12 lines, nearly identical - only log message differs)
3. **ensure block** with `send_end_signals` (identical in all 4)

Only the actual routing logic differs (2-5 lines per router).

### Proposed Refactor

Extract common logic to `RouterStage` base class using Template Method pattern:

```ruby
class RouterStage < Stage
  def run_stage(worker_ctx)
    setup_routing(worker_ctx)

    loop do
      item = worker_ctx.input_queue.pop

      # Common: Handle EndOfSource
      if item.is_a?(EndOfSource)
        worker_ctx.sources_expected << item.stage
        worker_ctx.sources_done << item.stage
        break if worker_ctx.sources_done == worker_ctx.sources_expected
        next
      end

      # Common: Handle RoutedItem from IPC
      if item.is_a?(Minigun::RoutedItem)
        handle_routed_item(worker_ctx, item)
        next
      end

      # Subclass-specific routing
      route_item(worker_ctx, item)
    end
  ensure
    send_end_signals(worker_ctx)
  end

  protected

  # Template methods for subclasses
  def setup_routing(worker_ctx); end
  def route_item(worker_ctx, item); raise NotImplementedError; end

  def handle_routed_item(worker_ctx, item)
    target = @targets.find { |t| t.name == item.target_stage }
    if target
      queue = worker_ctx.stage.task&.find_queue(target)
      queue&.<< item.item
    else
      Minigun.logger.warn "[#{self.class.name.split('::').last}] Unknown routed target: #{item.target_stage}"
    end
  end
end
```

Then each subclass becomes much simpler:

```ruby
class RouterBroadcastStage < RouterStage
  def route_item(worker_ctx, item)
    task = worker_ctx.stage.task
    @targets.each do |target|
      queue = task&.find_queue(target)
      queue&.<< item
    end
  end
end

class RouterRoundRobinStage < RouterStage
  def setup_routing(worker_ctx)
    task = worker_ctx.stage.task
    @target_queues = @targets.filter_map { |target| task&.find_queue(target) }
    @round_robin_index = 0
  end

  def route_item(_worker_ctx, item)
    @target_queues[@round_robin_index] << item
    @round_robin_index = (@round_robin_index + 1) % @target_queues.size
  end
end
```

### Benefits
- Reduces ~100 lines of duplicated code
- Single place to fix bugs in common logic
- Easier to add new router types
- Clear separation of concerns

### Confidence Level: 95%+

This is a slam-dunk refactor:
- Pure structural change with no behavioral change
- Comprehensive test coverage exists (12 router tests + integration tests)
- Template Method is a well-established pattern for this exact scenario

## Action

Proceeding with automatic refactor.
