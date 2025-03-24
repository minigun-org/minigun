# frozen_string_literal: true

require 'securerandom'
require 'concurrent'
require 'forwardable'
require 'yaml'
require 'logger'
require 'ostruct'
require 'zlib'
begin
  require 'msgpack'
rescue LoadError # rubocop:disable Lint/SuppressedException
end

require_relative 'minigun/version'
require_relative 'minigun/error'
require_relative 'minigun/hooks_mixin'
require_relative 'minigun/task'
require_relative 'minigun/pipeline'
require_relative 'minigun/runner'
require_relative 'minigun/dsl'

# Stages
require_relative 'minigun/stages/base'
require_relative 'minigun/stages/processor'
require_relative 'minigun/stages/accumulator'
require_relative 'minigun/stages/cow_fork'
require_relative 'minigun/stages/ipc_fork'

# Minigun is a high-performance parallel data processing framework.
module Minigun
  # Singleton logger instance
  @logger = Logger.new($stdout)

  class << self
    # Get the logger instance
    # @return [Logger] the logger
    attr_accessor :logger
  end
end
