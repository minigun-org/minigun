# frozen_string_literal: true

require 'minigun/version'
require 'minigun/error'
require 'minigun/task'
require 'minigun/runner'
require 'minigun/pipeline'
require 'minigun/stages/base'
require 'minigun/stages/processor'
require 'minigun/stages/accumulator'
require 'minigun/stages/cow_fork'
require 'minigun/stages/ipc_fork'

# Minigun is a high-performance parallel data processing framework.
module Minigun
end
