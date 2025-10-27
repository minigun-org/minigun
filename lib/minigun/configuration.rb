# frozen_string_literal: true

module Minigun
  # Global configuration for Minigun
  class Configuration
    attr_accessor :default_queue_size

    def initialize
      @default_queue_size = 1000  # Default bounded queue size for backpressure
    end
  end

  class << self
    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield(configuration)
    end

    # Convenience method
    def default_queue_size
      configuration.default_queue_size
    end
  end
end


