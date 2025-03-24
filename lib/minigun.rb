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
require_relative 'minigun/task'
require_relative 'minigun/pipeline'
require_relative 'minigun/stages/base'
require_relative 'minigun/stages/processor'
require_relative 'minigun/stages/accumulator'
require_relative 'minigun/stages/ipc_fork'
require_relative 'minigun/stages/cow_fork'
require_relative 'minigun/runner'
require_relative 'minigun/dsl'
require_relative 'minigun/pipeline_dsl'

# Minigun is a high-performance parallel data processing framework.
module Minigun
end
