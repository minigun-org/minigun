# Yield Syntax Implementation

## Overview

This document describes the implementation of native Ruby `yield` syntax support for Minigun pipeline stages using class-based stage definitions.

## Implementation Summary

### 1. Core Changes

#### `lib/minigun/queue_wrappers.rb`
- Added `to_proc` method to `OutputQueue` class
- Returns a memoized Proc that supports both:
  - `yield(item)` - emit to all downstream stages
  - `yield(item, to: :stage_name)` - emit to a specific stage via dynamic routing

#### `lib/minigun/stage.rb`
- Modified `Stage`, `ProducerStage`, and `ConsumerStage` classes to support class-based stages
- Added `call_stage_with_arity` private method to each class
- Method inspects the arity of custom `#call` methods and passes appropriate arguments
- Made `output` parameter optional based on method arity
- Fixed visibility issues ensuring `run_mode` and `run_stage` remain public

### 2. Usage

#### Defining Custom Stage Classes

```ruby
# Producer with yield
class NumberGenerator < Minigun::ProducerStage
  def call
    (1..10).each { |i| yield i }
  end
end

# Consumer/Processor with yield (arity 1)
class Doubler < Minigun::ConsumerStage
  def call(item)
    yield(item * 2)
  end
end

# Consumer/Processor with output parameter (arity 2)
class Optional < Minigun::ConsumerStage
  def call(item, output)
    output << item  # Can use output or yield
    yield(item + 1)
  end
end
```

#### Registering Custom Stages

```ruby
class MyPipeline
  include Minigun::DSL

  pipeline do
    custom_stage(NumberGenerator, :generate)
    custom_stage(Doubler, :transform)
    consumer :collect do |item|
      puts item
    end
  end
end
```

#### Dynamic Routing with Yield

```ruby
class Router < Minigun::ConsumerStage
  def call(item)
    if item.even?
      yield(item, to: :even_processor)
    else
      yield(item, to: :odd_processor)
    end
  end
end
```

### 3. Arity Handling

The implementation automatically detects the arity of the `#call` method:

- **Arity 0 or -1** (no args/optional): `call(&block)`
- **Arity 1 or -2** (one arg): `call(arg, &block)`
- **Arity 2+**: `call(arg1, arg2, &block)`

This makes the `output` parameter completely optional while maintaining backward compatibility.

### 4. Examples

- **`examples/00_quick_start_yield.rb`**: Basic yield syntax demonstration
- **`examples/63_yield_with_classes.rb`**: Comprehensive example with routing
- **`examples/69_yield_routing.rb`**: Dynamic routing with yield and to: parameter

### 5. Tests

- **`spec/unit/yield_syntax_spec.rb`**: Unit tests covering all arity combinations
- **`spec/integration/examples_spec.rb`**: Integration tests for yield examples

### 6. Dynamic Routing Support

**Dynamic Routing**: Stages can receive items exclusively through dynamic routing (via `yield(item, to: :stage_name)` or `output.to(:stage_name) << item`) without requiring static upstream connections in the DAG. The system automatically discovers dynamic sources when `EndOfSource` signals arrive and properly handles stage lifecycle.

This enables flexible routing patterns where stages are targeted based on runtime decisions without needing predefined DAG connections.

### 7. Backward Compatibility

- All existing block-based stages continue to work unchanged
- The `output <<` and `output.to <<` syntax remains fully supported
- Block-based and class-based stages can be mixed freely in the same pipeline

### 8. Benefits

1. **Natural Ruby Syntax**: Use native `yield` keyword instead of `output <<`
2. **Cleaner Code**: Class-based stages are more explicit and easier to test
3. **Flexible**: Optional `output` parameter based on method needs
4. **Composable**: Mix and match with block-based stages

## Technical Details

### OutputQueue#to_proc

```ruby
def to_proc
  @to_proc ||= proc do |item, to: nil|
    if to
      self.to(to) << item
    else
      self << item
    end
  end
end
```

This Proc is passed as a block argument to the `#call` method, enabling the use of `yield`.

### Visibility Fix

The `private` declarations were moved to ensure that public methods like `run_mode` and `run_stage` remain accessible to the `Worker` and `Pipeline` classes.

## Future Improvements

1. Address the dynamic routing limitation for stages with only dynamic inputs
2. Consider adding type hints or documentation for custom stage classes
3. Explore generator-style stages for more complex data generation patterns
