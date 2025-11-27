# Project: Minigun - High-Performance Data Pipeline Framework

## Tech Stack
- Language: Ruby 3.2+
- Testing: RSpec
- Linting: RuboCop

## Architecture

Minigun is a Ruby framework for building concurrent data processing pipelines.

### Core Components
- **Task**: Orchestrates pipelines, holds configuration
- **Pipeline**: Collection of stages that process data
- **Stage**: Single processing unit (producer, processor, consumer, accumulator)
- **DAG**: Directed Acyclic Graph for stage routing
- **Worker**: Executes stages in threads/processes
- **Executor**: Manages execution strategies (thread pool, fork pool, etc.)

### Directory Structure
```
lib/minigun/
├── dsl.rb           # DSL for defining pipelines
├── task.rb          # Task orchestration
├── pipeline.rb      # Pipeline management
├── stage.rb         # Stage types (Producer, Processor, Consumer, etc.)
├── dag.rb           # Directed Acyclic Graph
├── worker.rb        # Worker execution
├── runner.rb        # Pipeline runner with signal handling
├── execution/       # Execution strategies
├── hud/             # Terminal UI monitoring
└── queue_wrappers.rb # Thread-safe queue implementations
```

## Code Conventions

### DSL Usage
```ruby
class MyPipeline
  include Minigun::DSL

  pipeline do
    producer :source do |output|
      output << item
    end

    consumer :sink do |item|
      # final processing
    end
  end
end
```

### Testing
- Run tests: `bundle exec rspec`
- Run specific: `bundle exec rspec spec/unit/dsl_spec.rb`
- Examples: `ruby examples/00_quick_start.rb`

### Execution Contexts
```ruby
in_threads(5) do
  processor :parallel do |item, output|
    # runs in thread pool
  end
end

in_ipc_forks(4) do
  consumer :forked do |item|
    # runs in forked processes with IPC
  end
end
```

## Key Files
- `lib/minigun/dsl.rb` - Main DSL implementation
- `lib/minigun/task.rb` - Task orchestration
- `lib/minigun/pipeline.rb` - Pipeline execution
- `spec/integration/` - Integration tests
- `examples/` - Working examples
