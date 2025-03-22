# frozen_string_literal: true

require 'minigun/version'
require 'minigun/error'
require 'minigun/task'
require 'minigun/runner'
require 'minigun/pipeline'
require 'minigun/stages/base'
require 'minigun/stages/processor'  # Contains Producer, Processor, and Consumer implementations
require 'minigun/stages/accumulator'
require 'minigun/stages/cow_fork'   # Fork implementations used by Consumer
require 'minigun/stages/ipc_fork'

# Minigun is a high-performance data processing framework for Ruby
# that enables parallel processing with multi-threading and multi-processing
module Minigun
end
