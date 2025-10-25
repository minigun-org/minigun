# frozen_string_literal: true

require 'concurrent'
require 'logger'

module Minigun
  class Error < StandardError; end

  # Simple logger
  @logger = Logger.new($stdout)
  @logger.level = Logger::INFO

  class << self
    attr_accessor :logger
  end
end

require_relative 'minigun/version'
require_relative 'minigun/task'
require_relative 'minigun/dsl'

