# Configuration

Learn how to configure Minigun pipelines for different environments and requirements.

## Quick Start

```ruby
class ConfigurablePipeline
  include Minigun::DSL

  # Global execution strategy
  execution :thread, max: 20

  pipeline do
    producer :generate { 100.times { |i| emit(i) } }

    # Override for specific stage
    processor :transform, threads: 10, queue_size: 500 do |item, output|
      output << (item * 2)
    end

    consumer :save do |item|
      database.insert(item)
    end
  end
end
```

## Global Configuration

### Execution Strategy

Set the default execution strategy for all stages:

```ruby
class Pipeline
  include Minigun::DSL

  # Use threads by default
  execution :thread, max: 20

  # Or use forks
  execution :cow_fork, max: 8

  # Or IPC forks
  execution :ipc_fork, max: 4

  pipeline do
    # Stages inherit this execution strategy
  end
end
```

### Queue Sizes

Set default queue sizes:

```ruby
class Pipeline
  include Minigun::DSL

  # Set default queue size for all stages
  default_queue_size 1000

  pipeline do
    processor :stage1 do |item, output|
      # Uses queue_size: 1000
    end

    # Override for specific stage
    processor :stage2, queue_size: 5000 do |item, output|
      # Uses queue_size: 5000
    end
  end
end
```

## Stage-Level Configuration

### Thread Count

Control concurrency per stage:

```ruby
pipeline do
  # Low concurrency for CPU work
  processor :parse, threads: 5 do |item, output|
    output << JSON.parse(item)
  end

  # High concurrency for I/O work
  processor :fetch, threads: 50 do |id, output|
    output << HTTP.get("https://api.example.com/#{id}")
  end

  # Single threaded
  consumer :write_file, threads: 1 do |data|
    File.append('output.txt', data)
  end
end
```

### Execution Strategy Override

Override global strategy per stage:

```ruby
class Pipeline
  include Minigun::DSL

  # Default to threads
  execution :thread, max: 20

  pipeline do
    # Use threads (inherited)
    processor :fetch, threads: 50 do |url, output|
      output << HTTP.get(url)
    end

    # Override to use COW forks
    processor :compute, execution: :cow_fork, max: 8 do |data, output|
      output << expensive_computation(data)
    end

    # Back to threads (inherited)
    consumer :save, threads: 10 do |result|
      database.insert(result)
    end
  end
end
```

### Queue Configuration

Configure queues per stage:

```ruby
pipeline do
  # Small queue for fast stage
  processor :quick, threads: 10, queue_size: 100 do |item, output|
    output << item * 2
  end

  # Large queue for slow stage
  processor :slow, threads: 5, queue_size: 5000 do |item, output|
    output << expensive_operation(item)
  end

  # Unbounded queue (use with caution!)
  processor :buffer, threads: 1, queue_size: Float::INFINITY do |item, output|
    output << item
  end
end
```

## Environment-Specific Configuration

### Development

```ruby
class Pipeline
  include Minigun::DSL

  def self.development_config
    execution :inline  # Sequential, easy to debug
  end

  def self.test_config
    execution :inline  # Deterministic tests
    default_queue_size 10  # Small queues
  end

  def self.production_config
    execution :thread, max: 50
    default_queue_size 1000
  end

  # Apply based on environment
  case ENV['RAILS_ENV']
  when 'development'
    development_config
  when 'test'
    test_config
  when 'production'
    production_config
  end

  pipeline do
    # Pipeline definition
  end
end
```

### Using Rails Configuration

```ruby
# config/environments/development.rb
config.minigun = ActiveSupport::OrderedOptions.new
config.minigun.execution = :inline
config.minigun.max_threads = 5

# config/environments/production.rb
config.minigun = ActiveSupport::OrderedOptions.new
config.minigun.execution = :thread
config.minigun.max_threads = 50
config.minigun.max_forks = ENV.fetch('MINIGUN_MAX_FORKS', 8).to_i

# In your pipeline
class Pipeline
  include Minigun::DSL

  if defined?(Rails)
    execution Rails.configuration.minigun.execution,
              max: Rails.configuration.minigun.max_threads
  end

  pipeline do
    # ...
  end
end
```

## Dynamic Configuration

### Configuration from Environment Variables

```ruby
class Pipeline
  include Minigun::DSL

  # Read from environment
  execution_strategy = ENV.fetch('MINIGUN_EXECUTION', 'thread').to_sym
  max_workers = ENV.fetch('MINIGUN_MAX_WORKERS', '20').to_i

  execution execution_strategy, max: max_workers

  pipeline do
    # Thread count from environment
    processor :transform,
              threads: ENV.fetch('TRANSFORM_THREADS', '10').to_i do |item, output|
      output << transform(item)
    end
  end
end
```

### Configuration from File

```ruby
# config/minigun.yml
development:
  execution: inline
  max_threads: 5
  queue_size: 100

test:
  execution: inline
  max_threads: 2
  queue_size: 10

production:
  execution: thread
  max_threads: 50
  queue_size: 1000
  enable_monitoring: true

# In your pipeline
class Pipeline
  include Minigun::DSL

  config = YAML.load_file('config/minigun.yml')[ENV['RACK_ENV'] || 'development']

  execution config['execution'].to_sym, max: config['max_threads']
  default_queue_size config['queue_size']

  pipeline do
    # ...
  end
end
```

### Runtime Configuration

```ruby
class ConfigurablePipeline
  include Minigun::DSL

  attr_accessor :config

  def initialize(config = {})
    @config = default_config.merge(config)
  end

  def default_config
    {
      execution: :thread,
      max_threads: 20,
      queue_size: 500,
      batch_size: 100
    }
  end

  pipeline do
    processor :transform, threads: @config[:max_threads] do |item, output|
      output << transform(item)
    end

    accumulator :batch, max_size: @config[:batch_size] do |batch, output|
      output << batch
    end
  end
end

# Use with different configs
fast_pipeline = ConfigurablePipeline.new(max_threads: 50, batch_size: 500)
slow_pipeline = ConfigurablePipeline.new(max_threads: 5, batch_size: 50)
```

## Platform-Specific Configuration

### Automatic Platform Detection

```ruby
class Platform
  include Minigun::DSL

  # Detect platform and configure accordingly
  if Minigun::Platform.fork_supported?
    # Unix/Linux/Mac - use forks
    execution :cow_fork, max: Etc.nprocessors
  else
    # Windows/JRuby - use threads
    execution :thread, max: 20
  end

  pipeline do
    # Platform-appropriate execution
  end
end
```

### JRuby Configuration

```ruby
class Pipeline
  include Minigun::DSL

  # JRuby has true thread parallelism (no GVL)
  if RUBY_PLATFORM == 'java'
    execution :thread, max: Etc.nprocessors
  else
    # MRI - use forks for CPU work
    execution :cow_fork, max: Etc.nprocessors
  end

  pipeline do
    # ...
  end
end
```

## Hooks Configuration

### Global Hooks

```ruby
class Pipeline
  include Minigun::DSL

  before_run do
    logger.info("Pipeline starting: #{self.class.name}")
    @start_time = Time.now
  end

  after_run do
    duration = Time.now - @start_time
    logger.info("Pipeline completed in #{duration}s")
  end

  # For fork execution
  before_fork do
    # Disconnect database
    ActiveRecord::Base.connection_handler.clear_all_connections!
  end

  after_fork do
    # Reconnect in child process
    ActiveRecord::Base.establish_connection
  end

  pipeline do
    # ...
  end
end
```

### Conditional Hooks

```ruby
before_run do
  # Only in production
  if ENV['RAILS_ENV'] == 'production'
    notify_monitoring_service("Pipeline #{self.class.name} starting")
  end

  # Setup based on config
  if @config[:enable_profiling]
    require 'ruby-prof'
    RubyProf.start
  end
end

after_run do
  if @config[:enable_profiling]
    result = RubyProf.stop
    File.write('profile.html', result.to_html)
  end
end
```

## Logging Configuration

### Custom Logger

```ruby
class Pipeline
  include Minigun::DSL

  attr_accessor :logger

  def initialize(logger: Logger.new($stdout))
    @logger = logger
    @logger.level = log_level
  end

  def log_level
    case ENV['LOG_LEVEL']
    when 'debug' then Logger::DEBUG
    when 'info' then Logger::INFO
    when 'warn' then Logger::WARN
    when 'error' then Logger::ERROR
    else Logger::INFO
    end
  end

  pipeline do
    processor :transform do |item, output|
      logger.debug("Processing item: #{item}")
      result = transform(item)
      logger.debug("Transformed to: #{result}")
      output << result
    end
  end
end
```

### Structured Logging

```ruby
require 'json'

class Pipeline
  include Minigun::DSL

  def log_structured(level, message, **metadata)
    log_entry = {
      timestamp: Time.now.iso8601,
      level: level,
      pipeline: self.class.name,
      message: message,
      **metadata
    }

    logger.send(level, JSON.generate(log_entry))
  end

  pipeline do
    processor :transform do |item, output|
      log_structured(:info, "Processing item", item_id: item[:id])
      output << transform(item)
    end
  end
end
```

## Monitoring Configuration

### Enable HUD

```ruby
class Pipeline
  include Minigun::DSL

  def self.run_with_monitoring
    if ENV['MINIGUN_HUD'] == '1'
      require 'minigun/hud'
      Minigun::HUD.run_with_hud(new)
    else
      new.run
    end
  end

  pipeline do
    # ...
  end
end

# Run
Pipeline.run_with_monitoring
```

### Stats Collection

```ruby
class Pipeline
  include Minigun::DSL

  attr_accessor :stats_enabled

  def initialize(stats_enabled: true)
    @stats_enabled = stats_enabled
    @stats = {} if stats_enabled
  end

  after_run do
    if @stats_enabled
      log_statistics
      write_stats_file if ENV['WRITE_STATS'] == '1'
    end
  end

  def log_statistics
    logger.info("Pipeline Statistics:")
    logger.info("  Duration: #{stats.duration}s")
    logger.info("  Throughput: #{stats.throughput} items/s")
    logger.info("  Items processed: #{stats.items_processed}")
  end
end
```

## Resource Limits

### Memory Limits

```ruby
class Pipeline
  include Minigun::DSL

  before_run do
    @start_memory = current_memory_usage
  end

  after_run do
    memory_used = current_memory_usage - @start_memory

    if memory_used > memory_limit
      logger.warn("Pipeline used #{memory_used}MB (limit: #{memory_limit}MB)")
    end
  end

  def current_memory_usage
    `ps -o rss= -p #{Process.pid}`.to_i / 1024  # MB
  end

  def memory_limit
    ENV.fetch('MEMORY_LIMIT_MB', 1000).to_i
  end
end
```

### Timeout Configuration

```ruby
require 'timeout'

class Pipeline
  include Minigun::DSL

  def run_with_timeout(seconds = default_timeout)
    Timeout.timeout(seconds) do
      run
    end
  rescue Timeout::Error
    logger.error("Pipeline timed out after #{seconds} seconds")
    raise
  end

  def default_timeout
    ENV.fetch('PIPELINE_TIMEOUT', 3600).to_i  # 1 hour default
  end
end
```

## Configuration Validation

### Validate Before Running

```ruby
class Pipeline
  include Minigun::DSL

  before_run do
    validate_configuration!
  end

  def validate_configuration!
    # Check required environment variables
    raise ConfigError, "DATABASE_URL not set" unless ENV['DATABASE_URL']
    raise ConfigError, "API_KEY not set" unless ENV['API_KEY']

    # Check resource availability
    if execution_strategy == :cow_fork && max_workers > Etc.nprocessors
      logger.warn("max_workers (#{max_workers}) > CPU cores (#{Etc.nprocessors})")
    end

    # Check dependencies
    require 'http'  # Will raise LoadError if not installed
  rescue LoadError => e
    raise ConfigError, "Missing dependency: #{e.message}"
  end
end

class ConfigError < StandardError; end
```

## Configuration Best Practices

### 1. Use Environment Variables for Deployment

```ruby
# ✅ Good - configurable per environment
execution :thread, max: ENV.fetch('MAX_THREADS', '20').to_i

# ❌ Bad - hardcoded
execution :thread, max: 20
```

### 2. Provide Sensible Defaults

```ruby
# ✅ Good - works without configuration
def thread_count
  ENV.fetch('THREADS', default_thread_count.to_s).to_i
end

def default_thread_count
  case ENV['RAILS_ENV']
  when 'production' then 50
  when 'development' then 5
  else 10
  end
end

# ❌ Bad - requires configuration
threads: ENV['THREADS'].to_i  # Errors if not set
```

### 3. Validate Configuration Early

```ruby
# ✅ Good - fail fast
before_run do
  raise "Invalid thread count" if thread_count <= 0
  raise "Invalid queue size" if queue_size <= 0
end

# ❌ Bad - fails during execution
processor :stage, threads: invalid_config do |item, output|
  # Errors here are harder to debug
end
```

### 4. Document Configuration Options

```ruby
# Configuration:
#   MINIGUN_EXECUTION   - Execution strategy (thread|cow_fork|ipc_fork)
#   MINIGUN_MAX_WORKERS - Maximum concurrent workers (default: 20)
#   MINIGUN_QUEUE_SIZE  - Queue size between stages (default: 500)
#   MINIGUN_HUD         - Enable HUD monitoring (1|0, default: 0)
#   MINIGUN_LOG_LEVEL   - Logging level (debug|info|warn|error, default: info)
class Pipeline
  include Minigun::DSL
  # ...
end
```

## Complete Example

```ruby
# config/minigun.yml
default: &default
  execution: thread
  max_workers: 20
  queue_size: 500
  enable_hud: false
  log_level: info

development:
  <<: *default
  execution: inline
  max_workers: 5
  enable_hud: true
  log_level: debug

test:
  <<: *default
  execution: inline
  max_workers: 2
  queue_size: 10

production:
  <<: *default
  max_workers: <%= ENV.fetch('MINIGUN_MAX_WORKERS', 50) %>
  queue_size: <%= ENV.fetch('MINIGUN_QUEUE_SIZE', 1000) %>
  enable_hud: <%= ENV.fetch('MINIGUN_HUD', '0') == '1' %>
  log_level: <%= ENV.fetch('LOG_LEVEL', 'info') %>

# lib/configured_pipeline.rb
class ConfiguredPipeline
  include Minigun::DSL

  attr_reader :config, :logger

  def initialize(config_file: 'config/minigun.yml', env: ENV['RAILS_ENV'] || 'development')
    @config = load_config(config_file, env)
    @logger = setup_logger
    apply_configuration
  end

  def load_config(file, env)
    YAML.load(ERB.new(File.read(file)).result)[env]
  end

  def setup_logger
    logger = Logger.new($stdout)
    logger.level = Logger.const_get(config['log_level'].upcase)
    logger.formatter = proc do |severity, datetime, progname, msg|
      "#{datetime.strftime('%Y-%m-%d %H:%M:%S')} [#{severity}] #{msg}\n"
    end
    logger
  end

  def apply_configuration
    # Set execution strategy
    self.class.execution config['execution'].to_sym, max: config['max_workers']

    # Set default queue size
    self.class.default_queue_size config['queue_size']
  end

  before_run do
    validate_configuration!
    logger.info("Starting pipeline: #{self.class.name}")
    logger.info("Config: execution=#{config['execution']}, workers=#{config['max_workers']}")
  end

  after_run do
    logger.info("Pipeline completed: #{stats.items_processed} items in #{stats.duration}s")
  end

  pipeline do
    producer :generate do |output|
      logger.debug("Generating items")
      100.times { |i| output << i }
    end

    processor :transform, threads: config['max_workers'] / 2 do |item, output|
      logger.debug("Transforming item: #{item}")
      output << (item * 2)
    end

    consumer :save do |item|
      logger.debug("Saving item: #{item}")
      database.insert(item)
    end
  end

  def self.run_with_config(config_file: 'config/minigun.yml')
    pipeline = new(config_file: config_file)

    if pipeline.config['enable_hud']
      require 'minigun/hud'
      Minigun::HUD.run_with_hud(pipeline)
    else
      pipeline.run
    end
  end

  private

  def validate_configuration!
    raise ConfigError, "Invalid max_workers" if config['max_workers'] <= 0
    raise ConfigError, "Invalid queue_size" if config['queue_size'] <= 0
    raise ConfigError, "Invalid execution" unless [:inline, :thread, :cow_fork, :ipc_fork].include?(config['execution'].to_sym)
  end
end

# Usage
ConfiguredPipeline.run_with_config
```

## Key Takeaways

**Global Configuration:**
- Set execution strategy for all stages
- Configure default queue sizes
- Set up logging and monitoring

**Stage-Level Configuration:**
- Override thread counts per stage
- Customize queue sizes
- Use different execution strategies

**Environment-Specific:**
- Use environment variables for deployment
- Provide defaults for development
- Validate configuration early

**Best Practices:**
- Make configuration explicit and documented
- Provide sensible defaults
- Validate before running
- Use environment variables for deployment settings

## Next Steps

- [Error Handling](14_error_handling.md) - Handle configuration errors
- [Deployment](08_deployment.md) - Production configuration
- [Performance Tuning](11_performance_tuning.md) - Optimize configuration

---

**Configure wisely** for reliable, maintainable pipelines across all environments.
