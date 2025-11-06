# Contributing to Minigun

Thank you for your interest in contributing to Minigun! This guide will help you get started.

## Quick Start

```bash
# 1. Fork and clone
git clone https://github.com/YOUR_USERNAME/minigun.git
cd minigun

# 2. Install dependencies
bundle install

# 3. Run tests
bundle exec rspec

# 4. Make changes, test, and submit PR
```

## Development Setup

### Prerequisites

- **Ruby 3.2 or higher**
- **Git**
- **Bundler** (`gem install bundler`)

### Clone the Repository

```bash
git clone https://github.com/YOUR_USERNAME/minigun.git
cd minigun
```

### Install Dependencies

```bash
bundle install
```

Minigun has minimal dependencies:
- `concurrent-ruby` - Thread-safe data structures
- Development dependencies for testing

### Verify Setup

```bash
# Run the test suite
bundle exec rspec

# Run a simple example
bundle exec ruby examples/01_hello_world.rb
```

If tests pass, you're ready to contribute!

## Project Structure

```
minigun/
├── lib/                    # Main source code
│   └── minigun/
│       ├── dsl.rb         # Pipeline DSL
│       ├── pipeline.rb    # Core pipeline orchestration
│       ├── stage.rb       # Stage base class
│       ├── worker/        # Execution strategies
│       │   ├── inline.rb
│       │   ├── thread_pool.rb
│       │   ├── cow_fork.rb
│       │   └── ipc_fork.rb
│       ├── dag.rb         # Routing graph validation
│       ├── hud/           # Real-time monitoring
│       │   ├── display.rb
│       │   ├── renderer.rb
│       │   └── stats.rb
│       └── platform.rb    # Platform detection
├── spec/                  # Test suite
│   ├── integration/       # Integration tests
│   ├── unit/             # Unit tests
│   └── hud/              # HUD tests
├── examples/             # Working examples
├── docs/                 # Documentation
└── README.md             # Project overview
```

### Key Components

**Core Pipeline:**
- `lib/minigun/dsl.rb` - DSL for defining pipelines
- `lib/minigun/pipeline.rb` - Pipeline orchestration
- `lib/minigun/stage.rb` - Stage types (producer, processor, consumer, accumulator)

**Execution:**
- `lib/minigun/worker/` - Execution strategies (inline, threads, forks)
- `lib/minigun/task.rb` - Individual stage execution

**Routing:**
- `lib/minigun/dag.rb` - Directed acyclic graph validation
- `lib/minigun/router.rb` - Routing logic

**Monitoring:**
- `lib/minigun/hud/` - Real-time HUD interface
- `lib/minigun/stats.rb` - Performance statistics

## Running Tests

### Run All Tests

```bash
bundle exec rspec
```

### Run Specific Tests

```bash
# Single file
bundle exec rspec spec/integration/basic_pipeline_spec.rb

# Single test
bundle exec rspec spec/integration/basic_pipeline_spec.rb:25

# By tag
bundle exec rspec --tag integration
bundle exec rspec --tag ~slow  # Exclude slow tests
```

### Run Tests with Coverage

```bash
# With SimpleCov (if configured)
COVERAGE=true bundle exec rspec
```

### Continuous Testing

Use Guard for automatic test runs:

```bash
bundle exec guard
```

## Making Changes

### 1. Create a Branch

```bash
git checkout -b feature/my-new-feature
# or
git checkout -b fix/bug-description
```

Branch naming conventions:
- `feature/` - New features
- `fix/` - Bug fixes
- `docs/` - Documentation changes
- `refactor/` - Code refactoring
- `test/` - Test improvements

### 2. Make Your Changes

Write clean, well-documented code:

```ruby
# Good: Clear, documented
class NewFeature
  # Processes items using the new algorithm.
  #
  # @param item [Object] The item to process
  # @return [Object] The processed result
  def process(item)
    # Implementation
  end
end

# Bad: Unclear, no documentation
class NF
  def p(i)
    # Implementation
  end
end
```

### 3. Write Tests

All new features and bug fixes should include tests:

```ruby
# spec/unit/new_feature_spec.rb
RSpec.describe NewFeature do
  describe '#process' do
    it 'processes items correctly' do
      feature = NewFeature.new

      result = feature.process(input)

      expect(result).to eq(expected_output)
    end

    it 'handles edge cases' do
      feature = NewFeature.new

      result = feature.process(nil)

      expect(result).to be_nil
    end
  end
end
```

### 4. Run Tests

Ensure all tests pass:

```bash
bundle exec rspec
```

### 5. Lint Your Code

Check code style:

```bash
bundle exec rubocop
```

Fix auto-fixable issues:

```bash
bundle exec rubocop -a
```

## Testing Guidelines

### Unit Tests

Test individual classes/methods in isolation:

```ruby
RSpec.describe Minigun::Stage do
  describe '#run' do
    it 'executes the stage block' do
      executed = false
      stage = Minigun::Stage.new(:test) { executed = true }

      stage.run

      expect(executed).to be true
    end
  end
end
```

### Integration Tests

Test complete pipelines:

```ruby
RSpec.describe 'Basic Pipeline', :integration do
  it 'processes items through all stages' do
    class TestPipeline
      include Minigun::DSL

      pipeline do
        producer :generate { 10.times { |i| emit(i) } }
        processor :double { |n, output| output << n * 2 }
        consumer :collect { |n| results << n }
      end
    end

    pipeline = TestPipeline.new
    pipeline.run

    expect(pipeline.results.size).to eq(10)
  end
end
```

### Test Coverage

Aim for high test coverage:
- All new features should have tests
- Bug fixes should include regression tests
- Edge cases should be tested

## Code Style

Minigun follows standard Ruby style guidelines:

### General Rules

```ruby
# Use 2 spaces for indentation
def my_method
  do_something
end

# Use snake_case for methods and variables
user_name = fetch_user_name

# Use CamelCase for classes and modules
class MyPipeline
  include Minigun::DSL
end

# Use descriptive names
# Good
def process_user_data(user)
  # ...
end

# Bad
def p(u)
  # ...
end
```

### Documentation

Document public APIs:

```ruby
# Processes items through the pipeline.
#
# @param items [Array] Items to process
# @param options [Hash] Processing options
# @option options [Integer] :threads Number of threads to use
# @return [Hash] Processing results
def process(items, options = {})
  # Implementation
end
```

### Testing Patterns

```ruby
# Use descriptive test names
it 'processes items in parallel' do
  # ...
end

# Use let for test data
let(:test_data) { [1, 2, 3] }

# Use before blocks for setup
before do
  @pipeline = MyPipeline.new
end

# Use context for different scenarios
context 'with valid data' do
  # ...
end

context 'with invalid data' do
  # ...
end
```

## Submitting a Pull Request

### 1. Commit Your Changes

Write clear commit messages:

```bash
# Good commit messages
git commit -m "Add support for priority routing"
git commit -m "Fix deadlock in fork executor"
git commit -m "Update documentation for HUD interface"

# Bad commit messages
git commit -m "fix stuff"
git commit -m "WIP"
git commit -m "asdf"
```

Commit message format:
```
Type: Short description (50 chars max)

Longer explanation if needed. Wrap at 72 characters.

- Bullet points for multiple changes
- Reference issues: Fixes #123
```

Types: `feat`, `fix`, `docs`, `refactor`, `test`, `chore`

### 2. Push to Your Fork

```bash
git push origin feature/my-new-feature
```

### 3. Open a Pull Request

Go to GitHub and open a PR from your branch to `main`.

**PR Title:**
- Clear and descriptive
- Format: `[Type] Description`
- Example: `[Feature] Add priority routing support`

**PR Description:**
Include:
- What the PR does
- Why it's needed
- How to test it
- Screenshots (if UI changes)
- Related issues

Example:
```markdown
## Description
Adds support for priority-based routing to allow high-priority items to be
processed before low-priority items.

## Motivation
Users requested the ability to prioritize certain items in their pipelines
(#123).

## Changes
- Added `priority` option to routing DSL
- Implemented priority queue in router
- Added tests for priority routing
- Updated documentation

## Testing
```ruby
class PriorityPipeline
  include Minigun::DSL

  pipeline do
    processor :route, to: [:high, :low] do |item, output|
      if item[:priority] == :high
        output.to(:high) << item
      else
        output.to(:low) << item
      end
    end
  end
end
```

## Related Issues
Fixes #123
```

### 4. Respond to Feedback

Be responsive to review comments:
- Make requested changes
- Explain your reasoning if you disagree
- Be open to suggestions
- Thank reviewers for their time

### 5. Merge

Once approved, a maintainer will merge your PR.

## Development Workflow

### Typical Workflow

```bash
# 1. Update main branch
git checkout main
git pull upstream main

# 2. Create feature branch
git checkout -b feature/new-feature

# 3. Make changes
# ... edit files ...

# 4. Run tests frequently
bundle exec rspec

# 5. Commit incrementally
git add .
git commit -m "Add new feature"

# 6. Push and open PR
git push origin feature/new-feature
# Open PR on GitHub

# 7. Respond to feedback
# ... make changes ...
git commit -m "Address review feedback"
git push origin feature/new-feature
```

### Debugging

Use Ruby debugging tools:

```ruby
# Use pry for debugging
require 'pry'

def my_method
  binding.pry  # Execution stops here
  # ...
end
```

Run specific examples:

```bash
# Run example with output
bundle exec ruby examples/10_web_crawler.rb

# Run with HUD
MINIGUN_HUD=1 bundle exec ruby examples/10_web_crawler.rb
```

Enable debug logging:

```bash
MINIGUN_LOG_LEVEL=debug bundle exec ruby examples/my_example.rb
```

## Areas to Contribute

### Good First Issues

Look for issues tagged `good-first-issue`:
- Documentation improvements
- Bug fixes with clear reproduction steps
- Small feature enhancements
- Test coverage improvements

### Documentation

Documentation is always appreciated:
- Fix typos and unclear explanations
- Add examples to existing docs
- Write new guides or recipes
- Improve code comments

### Features

Potential features to add:
- New execution strategies
- Additional routing patterns
- Performance optimizations
- Platform-specific improvements
- Monitoring enhancements

### Bug Fixes

Found a bug? Great!
1. Open an issue describing the bug
2. Include steps to reproduce
3. Submit a PR with a fix and test

## Getting Help

### Communication Channels

- **GitHub Issues** - Bug reports, feature requests
- **GitHub Discussions** - Questions, ideas, general discussion
- **Pull Requests** - Code review, implementation feedback

### Questions

Before asking:
1. Check existing issues and discussions
2. Read the documentation
3. Search the codebase

When asking:
- Be specific about your problem
- Include code examples
- Show what you've tried
- Include error messages

## Code of Conduct

Be respectful and constructive:
- Welcome newcomers
- Be patient with questions
- Provide helpful feedback
- Respect different opinions
- Assume good intentions

## Release Process

(For maintainers)

1. Update version in `lib/minigun/version.rb`
2. Update `CHANGELOG.md`
3. Commit: `git commit -m "Release v1.2.3"`
4. Tag: `git tag v1.2.3`
5. Push: `git push origin main --tags`
6. Build gem: `gem build minigun.gemspec`
7. Publish: `gem push minigun-1.2.3.gem`

## Architecture Guidelines

### Performance Considerations

- Minimize allocations in hot paths
- Use concurrent data structures for thread safety
- Profile before optimizing
- Benchmark performance-critical changes

### Thread Safety

- Use `Concurrent::*` classes for shared state
- Avoid mutable shared state
- Document thread safety guarantees

### Error Handling

- Fail fast for programmer errors
- Recover gracefully from user errors
- Provide helpful error messages
- Log errors with context

## Testing Performance

Run performance benchmarks:

```bash
bundle exec ruby benchmarks/throughput_benchmark.rb
```

Compare before/after:

```bash
# Before changes
git checkout main
bundle exec ruby benchmarks/throughput_benchmark.rb > before.txt

# After changes
git checkout feature/my-feature
bundle exec ruby benchmarks/throughput_benchmark.rb > after.txt

# Compare
diff before.txt after.txt
```

## Additional Resources

### Learning

- [Ruby Style Guide](https://rubystyle.guide/)
- [RSpec Best Practices](https://rspec.rubystyle.guide/)
- [Git Workflow](https://guides.github.com/introduction/flow/)

### Tools

- [RuboCop](https://github.com/rubocop/rubocop) - Code linter
- [RSpec](https://rspec.info/) - Testing framework
- [Pry](https://github.com/pry/pry) - Debugging
- [SimpleCov](https://github.com/simplecov-ruby/simplecov) - Code coverage

## Thank You!

Thank you for contributing to Minigun! Your contributions help make Minigun better for everyone.

Questions? Open an issue or discussion on GitHub.

---

**Ready to contribute?** Pick a [good first issue](https://github.com/user/minigun/labels/good-first-issue) and get started!
