# frozen_string_literal: true

# Minigun is a high-performance data pipeline framework for Ruby
module Minigun
  # Global configuration for Minigun
  class Configuration
    attr_accessor :default_queue_size, :default_min_demand, :default_max_demand, :demand_timeout

    # Demand-based backpressure settings
    attr_accessor :demand_enabled # Enable demand system globally (default: false)  # Default min_demand threshold (default: 500)  # Default max_demand limit (default: 1000)      # Default timeout for demand wait (default: nil = infinite)

    def initialize
      @default_queue_size = 1000 # Default bounded queue size for backpressure

      # Demand settings - opt-in by default
      @demand_enabled = false
      @default_min_demand = 500
      @default_max_demand = 1000
      @demand_timeout = nil
    end
  end

  class << self
    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield(configuration)
    end

    # Convenience methods
    def default_queue_size
      configuration.default_queue_size
    end

    def demand_enabled?
      configuration.demand_enabled
    end

    def default_min_demand
      configuration.default_min_demand
    end

    def default_max_demand
      configuration.default_max_demand
    end

    def demand_timeout
      configuration.demand_timeout
    end
  end
end
