# frozen_string_literal: true

require_relative 'demand/tracker'
require_relative 'demand/channel'
require_relative 'demand/registry'
require_relative 'demand/aware_queues'

module Minigun
  # Demand-based backpressure system inspired by GenStage (Elixir).
  #
  # This module provides pull-based flow control where consumers request items
  # from producers using demand tokens. Producers block until demand is available,
  # preventing them from overwhelming slow consumers.
  #
  # ## Key Concepts
  #
  # - **Demand**: A request from consumer to producer for N items
  # - **Pending demand**: Items requested but not yet emitted
  # - **Watermarks**: min_demand/max_demand thresholds for auto-replenishment
  #
  # ## How It Works
  #
  # 1. Consumer sends initial demand (max_demand items)
  # 2. Producer waits for demand before emitting each item
  # 3. When pending demand drops below min_demand, consumer requests more
  # 4. Consumer requests (max_demand - pending) items to refill
  #
  # ## Example with Watermarks
  #
  # With max_demand=1000 and min_demand=500:
  #
  # ```
  # Initial: Consumer requests 1000 items
  #          Pending demand = 1000
  #
  # Step 1:  Producer sends 100 items → Pending demand = 900
  # Step 2:  Producer sends 100 items → Pending demand = 800
  # ...
  # Step 5:  Producer sends 100 items → Pending demand = 500 (hit min_demand!)
  #          Consumer requests 500 more → Pending demand = 1000
  # ```
  #
  # This creates a steady-state batch size of (max_demand - min_demand) items.
  #
  # ## Usage
  #
  # Enable demand mode in pipeline configuration:
  #
  # ```ruby
  # class MyPipeline
  #   include Minigun::DSL
  #
  #   pipeline demand: true do
  #     producer :source do |output|
  #       1000.times { |i| output << i }
  #     end
  #
  #     consumer :processor, min_demand: 100, max_demand: 500 do |item, output|
  #       output << process(item)
  #     end
  #   end
  # end
  # ```
  #
  # @see Demand::Tracker Core demand counting logic
  # @see Demand::Channel Producer-consumer communication
  # @see Demand::Registry Channel management
  #
  module Demand
  end
end
