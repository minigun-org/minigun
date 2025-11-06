# Testing Your Pipelines

Learn how to test your Minigun pipelines effectively.

## Why Test Pipelines?

Pipelines orchestrate complex data flows. Testing ensures:

- ✅ **Correctness** - Each stage transforms data as expected
- ✅ **Reliability** - Pipelines handle errors gracefully
- ✅ **Maintainability** - Refactor with confidence
- ✅ **Documentation** - Tests show how pipelines work

## Quick Start

```ruby
# spec/pipelines/data_pipeline_spec.rb
RSpec.describe DataPipeline do
  it 'processes items correctly' do
    pipeline = DataPipeline.new

    result = pipeline.run

    expect(result[:status]).to eq(:completed)
    expect(pipeline.results.size).to eq(100)
  end
end
```

## Testing Strategies

### 1. Unit Testing: Individual Stages

Test stage logic in isolation:

```ruby
class MyPipeline
  include Minigun::DSL

  pipeline do
    processor :double do |n, output|
      output << (n * 2)
    end

    processor :filter_even do |n, output|
      output << n if n.even?
    end
  end
end

# spec/pipelines/my_pipeline_spec.rb
RSpec.describe MyPipeline do
  let(:pipeline) { described_class.new }

  describe '#double' do
    it 'doubles numbers' do
      # Test stage logic directly
      input = 5
      output = []

      pipeline.send(:double, input, output)

      expect(output).to eq([10])
    end
  end

  describe '#filter_even' do
    it 'filters even numbers' do
      output = []

      pipeline.send(:filter_even, 4, output)
      expect(output).to eq([4])

      output.clear
      pipeline.send(:filter_even, 5, output)
      expect(output).to be_empty
    end
  end
end
```

### 2. Integration Testing: Full Pipeline

Test the complete pipeline:

```ruby
RSpec.describe DataPipeline do
  it 'processes all items through the pipeline' do
    pipeline = DataPipeline.new

    result = pipeline.run

    expect(result[:status]).to eq(:completed)
    expect(result[:duration]).to be > 0
  end

  it 'transforms data correctly end-to-end' do
    pipeline = DataPipeline.new

    pipeline.run

    # Verify final results
    expect(pipeline.results.size).to eq(50)
    expect(pipeline.results.first).to include(:id, :name, :processed_at)
  end
end
```

### 3. Testing with Test Data

Create test fixtures:

```ruby
RSpec.describe ETLPipeline do
  let(:test_data) do
    [
      { id: 1, name: 'Alice', age: 30 },
      { id: 2, name: 'Bob', age: 25 },
      { id: 3, name: 'Charlie', age: 35 }
    ]
  end

  it 'processes test data' do
    pipeline = ETLPipeline.new(data: test_data)

    pipeline.run

    expect(pipeline.results.size).to eq(3)
    expect(pipeline.results.map { |r| r[:name] }).to contain_exactly('Alice', 'Bob', 'Charlie')
  end
end
```

## Testing Patterns

### Pattern 1: Collecting Results

Make results observable for testing:

```ruby
class TestablePipeline
  include Minigun::DSL

  attr_reader :results, :errors

  def initialize
    @results = Concurrent::Array.new
    @errors = Concurrent::Array.new
  end

  pipeline do
    producer :generate { 10.times { |i| emit(i) } }

    processor :transform do |n, output|
      output << (n * 2)
    end

    consumer :collect do |n|
      @results << n
    end
  end
end

# Test
RSpec.describe TestablePipeline do
  it 'collects all results' do
    pipeline = TestablePipeline.new

    pipeline.run

    expect(pipeline.results).to eq([0, 2, 4, 6, 8, 10, 12, 14, 16, 18])
  end
end
```

### Pattern 2: Mocking External Dependencies

Use dependency injection:

```ruby
class DataPipeline
  include Minigun::DSL

  def initialize(database: Database, api_client: APIClient)
    @database = database
    @api_client = api_client
  end

  pipeline do
    producer :fetch_ids do |output|
      @database.find_each { |record| output << record.id }
    end

    processor :enrich, threads: 10 do |id, output|
      data = @api_client.fetch(id)
      output << data
    end

    consumer :save do |data|
      @database.insert(data)
    end
  end
end

# Test with mocks
RSpec.describe DataPipeline do
  let(:mock_database) { double('Database') }
  let(:mock_api) { double('APIClient') }
  let(:pipeline) { DataPipeline.new(database: mock_database, api_client: mock_api) }

  before do
    allow(mock_database).to receive(:find_each).and_yield(double(id: 1)).and_yield(double(id: 2))
    allow(mock_api).to receive(:fetch).with(1).and_return({ id: 1, data: 'A' })
    allow(mock_api).to receive(:fetch).with(2).and_return({ id: 2, data: 'B' })
    allow(mock_database).to receive(:insert)
  end

  it 'fetches and enriches data' do
    pipeline.run

    expect(mock_api).to have_received(:fetch).with(1)
    expect(mock_api).to have_received(:fetch).with(2)
    expect(mock_database).to have_received(:insert).twice
  end
end
```

### Pattern 3: Testing Error Handling

```ruby
class ResilientPipeline
  include Minigun::DSL

  attr_reader :errors

  def initialize
    @errors = Concurrent::Array.new
  end

  pipeline do
    processor :process do |item, output|
      begin
        result = risky_operation(item)
        output << result
      rescue => e
        @errors << { item: item, error: e.message }
      end
    end
  end
end

# Test
RSpec.describe ResilientPipeline do
  it 'captures errors without crashing' do
    pipeline = ResilientPipeline.new
    allow(pipeline).to receive(:risky_operation).and_raise('Boom!')

    expect { pipeline.run }.not_to raise_error

    expect(pipeline.errors).not_to be_empty
    expect(pipeline.errors.first[:error]).to eq('Boom!')
  end
end
```

### Pattern 4: Testing Routing Logic

```ruby
class RoutingPipeline
  include Minigun::DSL

  attr_reader :high_priority, :normal_priority

  def initialize
    @high_priority = Concurrent::Array.new
    @normal_priority = Concurrent::Array.new
  end

  pipeline do
    producer :items do |output|
      [
        { id: 1, priority: :high },
        { id: 2, priority: :normal },
        { id: 3, priority: :high }
      ].each { |item| output << item }
    end

    processor :route, to: [:high_handler, :normal_handler] do |item, output|
      if item[:priority] == :high
        output.to(:high_handler) << item
      else
        output.to(:normal_handler) << item
      end
    end

    consumer :high_handler do |item|
      @high_priority << item
    end

    consumer :normal_handler do |item|
      @normal_priority << item
    end
  end
end

# Test
RSpec.describe RoutingPipeline do
  it 'routes by priority correctly' do
    pipeline = RoutingPipeline.new

    pipeline.run

    expect(pipeline.high_priority.size).to eq(2)
    expect(pipeline.normal_priority.size).to eq(1)
    expect(pipeline.high_priority.map { |i| i[:id] }).to contain_exactly(1, 3)
  end
end
```

## Testing Execution Strategies

### Testing with Inline Execution

Use inline execution for deterministic, debuggable tests:

```ruby
class MyPipeline
  include Minigun::DSL

  # Override execution for tests
  def self.for_testing
    new.tap { |p| p.execution = :inline }
  end

  pipeline do
    processor :process, threads: 10 do |item, output|
      output << process(item)
    end
  end
end

# Test
RSpec.describe MyPipeline do
  it 'processes items' do
    pipeline = MyPipeline.for_testing  # Use inline execution

    pipeline.run

    # Tests are deterministic and debuggable
    expect(pipeline.results).to eq([expected_results])
  end
end
```

### Testing Thread Safety

Test concurrent execution:

```ruby
class ConcurrentPipeline
  include Minigun::DSL

  attr_reader :counter

  def initialize
    @counter = Concurrent::AtomicFixnum.new(0)
  end

  pipeline do
    producer :items { 100.times { |i| emit(i) } }

    processor :count, threads: 10 do |item, output|
      @counter.increment
      output << item
    end
  end
end

# Test
RSpec.describe ConcurrentPipeline do
  it 'handles concurrency safely' do
    pipeline = ConcurrentPipeline.new

    pipeline.run

    expect(pipeline.counter.value).to eq(100)
  end

  it 'produces consistent results across runs' do
    results = 10.times.map do
      pipeline = ConcurrentPipeline.new
      pipeline.run
      pipeline.counter.value
    end

    expect(results.uniq).to eq([100])  # Always 100, never race conditions
  end
end
```

### Testing Fork Execution

Test that fork logic works (or skip on Windows):

```ruby
RSpec.describe ForkPipeline do
  it 'uses fork execution', skip: !Minigun::Platform.fork_supported? do
    pipeline = ForkPipeline.new

    expect(pipeline).to receive(:fork).at_least(:once)

    pipeline.run
  end

  it 'falls back to threads on Windows' do
    allow(Minigun::Platform).to receive(:fork_supported?).and_return(false)

    pipeline = ForkPipeline.new

    expect(pipeline.execution_strategy).to eq(:thread)
  end
end
```

## Testing Hooks

### Testing Lifecycle Hooks

```ruby
class HookedPipeline
  include Minigun::DSL

  attr_reader :setup_called, :teardown_called

  before_run do
    @setup_called = true
    @start_time = Time.now
  end

  after_run do
    @teardown_called = true
    @duration = Time.now - @start_time
  end

  pipeline do
    producer :items { 10.times { |i| emit(i) } }
    consumer :process { |i| process(i) }
  end
end

# Test
RSpec.describe HookedPipeline do
  it 'calls hooks in order' do
    pipeline = HookedPipeline.new

    expect(pipeline.setup_called).to be_nil
    expect(pipeline.teardown_called).to be_nil

    pipeline.run

    expect(pipeline.setup_called).to be true
    expect(pipeline.teardown_called).to be true
  end
end
```

### Testing Fork Hooks

```ruby
class DatabasePipeline
  include Minigun::DSL

  attr_reader :disconnected, :reconnected

  before_fork do
    @disconnected = true
    Database.disconnect
  end

  after_fork do
    @reconnected = true
    Database.reconnect
  end

  pipeline do
    processor :work, execution: :cow_fork, max: 2 do |item, output|
      output << Database.query(item)
    end
  end
end

# Test
RSpec.describe DatabasePipeline, skip: !Minigun::Platform.fork_supported? do
  it 'disconnects before fork' do
    pipeline = DatabasePipeline.new
    expect(Database).to receive(:disconnect)

    pipeline.run
  end

  it 'reconnects after fork' do
    pipeline = DatabasePipeline.new
    expect(Database).to receive(:reconnect).at_least(:once)

    pipeline.run
  end
end
```

## Testing Real-World Scenarios

### Example 1: ETL Pipeline Test

```ruby
# spec/pipelines/user_etl_pipeline_spec.rb
RSpec.describe UserETLPipeline do
  let(:source_db) { double('SourceDB') }
  let(:target_db) { double('TargetDB') }
  let(:pipeline) { UserETLPipeline.new(source: source_db, target: target_db) }

  let(:test_users) do
    [
      { id: 1, name: 'Alice', email: 'alice@example.com' },
      { id: 2, name: 'Bob', email: 'bob@example.com' }
    ]
  end

  before do
    allow(source_db).to receive(:find_each).and_yield(test_users[0]).and_yield(test_users[1])
    allow(target_db).to receive(:insert_many)
  end

  it 'extracts users from source' do
    pipeline.run

    expect(source_db).to have_received(:find_each)
  end

  it 'transforms user data' do
    pipeline.run

    expect(target_db).to have_received(:insert_many) do |users|
      expect(users.first).to include(:id, :name, :email, :migrated_at)
    end
  end

  it 'loads data in batches' do
    allow(source_db).to receive(:find_each).and_yield(*100.times.map { |i| { id: i } })

    pipeline.run

    # Verify batching (batch size = 50)
    expect(target_db).to have_received(:insert_many).twice
  end

  it 'handles transformation errors gracefully' do
    allow(source_db).to receive(:find_each).and_yield({ id: 1, name: nil })  # Invalid

    expect { pipeline.run }.not_to raise_error

    expect(pipeline.errors.size).to eq(1)
    expect(pipeline.errors.first[:error]).to include('name')
  end
end
```

### Example 2: Web Scraper Test

```ruby
# spec/pipelines/web_scraper_spec.rb
RSpec.describe WebScraper do
  let(:http_client) { double('HTTPClient') }
  let(:scraper) { WebScraper.new(http: http_client) }

  let(:mock_html) { '<html><body><h1>Test</h1></body></html>' }

  before do
    allow(http_client).to receive(:get).and_return(double(body: mock_html, status: 200))
  end

  it 'fetches URLs' do
    scraper.run

    expect(http_client).to have_received(:get).at_least(:once)
  end

  it 'parses HTML' do
    scraper.run

    expect(scraper.results.first).to include(:title)
    expect(scraper.results.first[:title]).to eq('Test')
  end

  it 'handles HTTP errors' do
    allow(http_client).to receive(:get).and_raise(HTTP::TimeoutError)

    expect { scraper.run }.not_to raise_error

    expect(scraper.errors).not_to be_empty
    expect(scraper.errors.first[:error]).to include('Timeout')
  end

  it 'respects rate limiting' do
    start_time = Time.now

    scraper.run

    duration = Time.now - start_time

    # Should take at least N seconds (rate limiting)
    expect(duration).to be >= 1.0
  end
end
```

### Example 3: Batch Processor Test

```ruby
# spec/pipelines/batch_processor_spec.rb
RSpec.describe BatchProcessor do
  it 'processes all items' do
    processor = BatchProcessor.new(batch_size: 100)

    processor.run

    expect(processor.processed_count).to eq(1000)
  end

  it 'batches correctly' do
    processor = BatchProcessor.new(batch_size: 100)

    processor.run

    # 1000 items / 100 per batch = 10 batches
    expect(processor.batch_count).to eq(10)
  end

  it 'handles partial batches' do
    processor = BatchProcessor.new(batch_size: 100)
    allow(processor).to receive(:items).and_return(Array.new(250))

    processor.run

    # 250 items = 2 full batches + 1 partial (50 items)
    expect(processor.batch_count).to eq(3)
  end
end
```

## Best Practices

### 1. Test Behavior, Not Implementation

```ruby
# ❌ Testing implementation details
it 'uses 10 threads' do
  expect(pipeline.thread_count).to eq(10)
end

# ✅ Testing behavior
it 'processes items concurrently' do
  pipeline.run
  expect(pipeline.results.size).to eq(100)
end
```

### 2. Use Realistic Test Data

```ruby
# ❌ Trivial test data
let(:test_data) { [1, 2, 3] }

# ✅ Realistic test data
let(:test_data) do
  100.times.map do |i|
    {
      id: i,
      name: Faker::Name.name,
      email: Faker::Internet.email,
      created_at: i.days.ago
    }
  end
end
```

### 3. Test Edge Cases

```ruby
describe 'edge cases' do
  it 'handles empty input' do
    pipeline = Pipeline.new(data: [])
    pipeline.run
    expect(pipeline.results).to be_empty
  end

  it 'handles single item' do
    pipeline = Pipeline.new(data: [1])
    pipeline.run
    expect(pipeline.results.size).to eq(1)
  end

  it 'handles nil values' do
    pipeline = Pipeline.new(data: [nil, 1, nil, 2])
    pipeline.run
    expect(pipeline.results).to contain_exactly(1, 2)
  end
end
```

### 4. Use Test Helpers

```ruby
# spec/support/pipeline_helpers.rb
module PipelineHelpers
  def run_pipeline_and_collect_results(pipeline_class, data)
    pipeline = pipeline_class.new(data: data)
    pipeline.run
    pipeline.results
  end

  def expect_pipeline_success(pipeline)
    result = pipeline.run
    expect(result[:status]).to eq(:completed)
  end
end

RSpec.configure do |config|
  config.include PipelineHelpers
end

# Use in tests
RSpec.describe MyPipeline do
  it 'processes data' do
    results = run_pipeline_and_collect_results(MyPipeline, test_data)
    expect(results.size).to eq(10)
  end
end
```

### 5. Test Performance Regressions

```ruby
# spec/pipelines/performance_spec.rb
RSpec.describe DataPipeline, :performance do
  it 'completes within acceptable time' do
    pipeline = DataPipeline.new

    duration = Benchmark.realtime { pipeline.run }

    expect(duration).to be < 5.0  # Should complete in < 5 seconds
  end

  it 'maintains throughput' do
    pipeline = DataPipeline.new

    pipeline.run

    throughput = pipeline.results.size / pipeline.duration
    expect(throughput).to be >= 100  # At least 100 items/sec
  end
end
```

## Testing with Different Test Frameworks

### RSpec

```ruby
# spec/spec_helper.rb
RSpec.configure do |config|
  config.before(:suite) do
    # Setup before all tests
  end

  config.before(:each) do
    # Setup before each test
  end
end

# spec/pipelines/my_pipeline_spec.rb
RSpec.describe MyPipeline do
  subject(:pipeline) { described_class.new }

  describe '#run' do
    it 'processes items' do
      expect { pipeline.run }.not_to raise_error
    end
  end
end
```

### Minitest

```ruby
# test/test_helper.rb
require 'minitest/autorun'
require 'minigun'

# test/pipelines/my_pipeline_test.rb
class MyPipelineTest < Minitest::Test
  def setup
    @pipeline = MyPipeline.new
  end

  def test_processes_items
    @pipeline.run

    assert_equal 100, @pipeline.results.size
  end

  def test_handles_errors
    assert_nothing_raised { @pipeline.run }
  end
end
```

## Continuous Integration

### GitHub Actions

```yaml
# .github/workflows/test.yml
name: Tests

on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest

    steps:
      - uses: actions/checkout@v2

      - name: Set up Ruby
        uses: ruby/setup-ruby@v1
        with:
          ruby-version: 3.2
          bundler-cache: true

      - name: Run tests
        run: bundle exec rspec

      - name: Run pipeline integration tests
        run: bundle exec rspec spec/pipelines --tag integration
```

## Key Takeaways

**Testing Strategies:**
- Unit test individual stages in isolation
- Integration test full pipelines end-to-end
- Use inline execution for deterministic tests

**Best Practices:**
- Make results observable with `attr_reader`
- Use dependency injection for mocking
- Test error handling explicitly
- Test routing logic with multiple paths
- Use realistic test data

**What to Test:**
- Data transformation correctness
- Error handling and resilience
- Routing logic
- Thread safety (with concurrent execution)
- Performance regressions

## Next Steps

- [Performance Tuning](11_performance_tuning.md) - Optimize your pipelines
- [API Reference](09_api_reference.md) - Complete DSL documentation
- [Recipes](../recipes/) - Real-world pipeline examples

---

**Ready to test?** Write tests as you build your pipelines for maximum confidence.
