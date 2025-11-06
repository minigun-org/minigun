# Hello World

Let's build your first Minigun pipeline! We'll start with a simple example and gradually add complexity.

## The Simplest Pipeline

Here's a minimal Minigun pipeline that generates, transforms, and outputs data:

```ruby
require 'minigun'

class HelloPipeline
  include Minigun::DSL

  pipeline do
    producer :generate do |output|
      output << "Hello, World!"
    end

    consumer :print do |message|
      puts message
    end
  end
end

# Run the pipeline
HelloPipeline.new.run
# Output: Hello, World!
```

### Breaking It Down

1. **Include the DSL**: `include Minigun::DSL` gives your class the `pipeline` method
2. **Define a pipeline**: The `pipeline` block contains your stage definitions
3. **Producer stage**: Generates data using `output <<`
4. **Consumer stage**: Receives and prints the data
5. **Run it**: Call `.run` to execute the pipeline

## Adding Transformation

Let's add a processor stage to transform the data:

```ruby
class TransformPipeline
  include Minigun::DSL

  pipeline do
    # Generate data
    producer :generate do |output|
      output << "hello"
    end

    # Transform it
    processor :uppercase do |text, output|
      output << text.upcase
    end

    # Output it
    consumer :print do |text|
      puts text
    end
  end
end

TransformPipeline.new.run
# Output: HELLO
```

**What's New:**
- **Processor stage** (`uppercase`) - Takes input, produces output
- **Two parameters** - `text` (input) and `output` (where to send results)

## Processing Multiple Items

Pipelines really shine when processing multiple items:

```ruby
class NumberPipeline
  include Minigun::DSL

  attr_accessor :results

  def initialize
    @results = []
    @mutex = Mutex.new
  end

  pipeline do
    # Generate 10 numbers
    producer :generate do |output|
      10.times { |i| output << i }
    end

    # Square each number
    processor :square do |number, output|
      output << (number ** 2)
    end

    # Collect results
    consumer :collect do |squared|
      @mutex.synchronize { results << squared }
    end
  end
end

pipeline = NumberPipeline.new
pipeline.run

puts "Results: #{pipeline.results.sort.inspect}"
# Results: [0, 1, 4, 9, 16, 25, 36, 49, 64, 81]
```

**Key Points:**
- Each item flows through the pipeline independently
- The processor is called once for each input item
- Use a `Mutex` when writing to shared state (thread safety)

## Multiple Processors

Chain multiple transformation steps:

```ruby
class ChainedPipeline
  include Minigun::DSL

  pipeline do
    producer :generate do |output|
      5.times { |i| output << i + 1 }
    end

    processor :double do |n, output|
      output << (n * 2)
    end

    processor :add_ten do |n, output|
      output << (n + 10)
    end

    consumer :print do |result|
      puts "Result: #{result}"
    end
  end
end

ChainedPipeline.new.run
# Output:
# Result: 12  (1 * 2 + 10)
# Result: 14  (2 * 2 + 10)
# Result: 16  (3 * 2 + 10)
# Result: 18  (4 * 2 + 10)
# Result: 20  (5 * 2 + 10)
```

Data flows through each stage in sequence:
```
1 → double → 2 → add_ten → 12 → print
2 → double → 4 → add_ten → 14 → print
...
```

## Filtering Data

Processors can choose whether to emit items:

```ruby
class FilterPipeline
  include Minigun::DSL

  pipeline do
    producer :generate do |output|
      10.times { |i| output << i }
    end

    processor :evens_only do |number, output|
      output << number if number.even?
    end

    consumer :print do |number|
      puts "Even number: #{number}"
    end
  end
end

FilterPipeline.new.run
# Output:
# Even number: 0
# Even number: 2
# Even number: 4
# Even number: 6
# Even number: 8
```

**Filtering Pattern:**
- Don't call `output <<` for items you want to filter out
- Only emit items that pass your condition

## Practical Example: Word Counter

Let's build something useful—a word frequency counter:

```ruby
class WordCounter
  include Minigun::DSL

  attr_accessor :word_counts

  def initialize
    @word_counts = Hash.new(0)
    @mutex = Mutex.new
  end

  pipeline do
    # Generate sentences
    producer :sentences do |output|
      sentences = [
        "the quick brown fox",
        "jumped over the lazy dog",
        "the fox was very quick"
      ]
      sentences.each { |s| output << s }
    end

    # Split into words
    processor :split do |sentence, output|
      sentence.split.each { |word| output << word }
    end

    # Normalize
    processor :normalize do |word, output|
      output << word.downcase.gsub(/[^a-z]/, '')
    end

    # Count occurrences
    consumer :count do |word|
      @mutex.synchronize { word_counts[word] += 1 }
    end
  end
end

counter = WordCounter.new
counter.run

puts "Word frequencies:"
counter.word_counts.sort_by { |_, count| -count }.each do |word, count|
  puts "  #{word}: #{count}"
end
# Output:
#   the: 3
#   quick: 2
#   fox: 2
#   ...
```

## Understanding Data Flow

Here's how data flows through the word counter:

```
"the quick brown fox"
    ↓ [split]
"the", "quick", "brown", "fox"
    ↓ [normalize]
"the", "quick", "brown", "fox"
    ↓ [count]
{the: 1, quick: 1, brown: 1, fox: 1}

"jumped over the lazy dog"
    ↓ [split]
"jumped", "over", "the", "lazy", "dog"
    ↓ [normalize]
"jumped", "over", "the", "lazy", "dog"
    ↓ [count]
{the: 2, quick: 1, brown: 1, fox: 1, jumped: 1, ...}
```

Each stage processes items as they become available.

## Try It Yourself

Experiment with these variations:

1. **Add a filter stage** - Remove common words like "the", "a", "an"
2. **Add a minimum length filter** - Only count words with 4+ characters
3. **Add statistics** - Count total words processed

Example with a filter:

```ruby
COMMON_WORDS = %w[the a an and or but].freeze

processor :remove_common do |word, output|
  output << word unless COMMON_WORDS.include?(word)
end
```

## Key Takeaways

- **Pipelines** contain stages connected in sequence
- **Producers** generate data, **consumers** process final results
- **Processors** transform data and pass it along
- Each item flows through stages independently
- Use `output <<` to send data to the next stage
- Use `Mutex` for thread-safe access to shared state

## What's Next?

Now that you understand basic pipelines, let's explore the different stage types in depth.

→ [**Continue to Stages**](03_stages.md)

---

**See Also:**
- [Example: Quick Start](../../examples/00_quick_start.rb) - Working example
- [Stage Guide](../guides/stages/overview.md) - Detailed stage documentation
- [API Reference: DSL](../guides/09_api_reference.md) - Complete DSL reference
