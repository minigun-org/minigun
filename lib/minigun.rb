# frozen_string_literal: true

require 'concurrent'
require 'securerandom'
require 'logger'
require 'English'

# Minigun is a high-performance data pipeline framework for Ruby
module Minigun
  class Error < StandardError; end

  # Raised when a stage name conflicts with another at the same pipeline level
  class StageNameConflict < Error; end

  # Raised when routing cannot resolve an ambiguous stage name
  class AmbiguousRoutingError < Error; end

  # Simple logger
  @logger = Logger.new($stdout)
  @logger.level = Logger::INFO

  class << self
    attr_accessor :logger

    # Create a task using the functional DSL
    #
    # @param name [String] Optional task name
    # @yield Block containing pipeline definition (evaluated in instance context)
    # @return [Object] Instance with DSL methods and run/start capabilities
    #
    # @example
    #   task = Minigun.task('my_task') do
    #     producer :source do |output|
    #       10.times { |i| output << i }
    #     end
    #     consumer :sink do |item|
    #       puts item
    #     end
    #   end
    #   task.start
    def task(name = nil, &block)
      # Create anonymous class with DSL
      klass = Class.new do
        include Minigun::DSL

        def initialize(task_name, &definition_block)
          @task_name = task_name
          @definition_block = definition_block
        end

        def self.define_pipeline_from_block(definition_block)
          pipeline(&definition_block)
        end
      end

      # Define the pipeline from the block
      klass.define_pipeline_from_block(block) if block

      # Return instance
      klass.new(name, &block)
    end

    alias_method :pipeline, :task
  end
end

require_relative 'minigun/version'
require_relative 'minigun/platform'
require_relative 'minigun/configuration'
require_relative 'minigun/signal'
require_relative 'minigun/queue_wrappers'
require_relative 'minigun/worker'
require_relative 'minigun/execution/executor'
require_relative 'minigun/stats'
require_relative 'minigun/stage_registry'
require_relative 'minigun/demand'
require_relative 'minigun/stage'
require_relative 'minigun/dag'
require_relative 'minigun/pipeline'
require_relative 'minigun/runner'
require_relative 'minigun/task'
require_relative 'minigun/dsl'
require_relative 'minigun/hud'
require_relative 'minigun/cluster'
