# frozen_string_literal: true

module Minigun
  # Sentinel object to signal all upstream stages have completed
  class AllUpstreamsDone
    attr_reader :stage_name

    def self.instance(stage_name)
      @instances ||= {}
      @instances[stage_name] ||= new(stage_name)
    end

    def initialize(stage_name)
      @stage_name = stage_name
    end

    def to_s
      "AllUpstreamsDone(#{@stage_name})"
    end

    def inspect
      to_s
    end
  end

  # Wrapper around stage input queue that handles END messages
  class InputQueue
    def initialize(queue, stage_name, expected_sources)
      @queue = queue
      @stage_name = stage_name
      @sources_expected = Set.new(expected_sources)
      @sources_done = Set.new
    end

    # Pop items from queue, consuming END messages
    # Returns AllUpstreamsDone sentinel when all upstreams are done
    def pop
      loop do
        item = @queue.pop

        # Handle END messages
        if item.is_a?(Message) && item.end_of_stream?
          @sources_expected << item.source  # Discover dynamic sources
          @sources_done << item.source

          # All sources done? Return sentinel
          return AllUpstreamsDone.instance(@stage_name) if @sources_done == @sources_expected

          # More sources pending, keep looping to get next item
          next
        end

        # Regular item
        return item
      end
    end
  end

  # Wrapper around stage output that routes to downstream queues
  class OutputQueue
    attr_reader :items_produced

    def initialize(stage_name, downstream_queues, all_stage_queues, runtime_edges)
      @stage_name = stage_name
      @downstream_queues = downstream_queues  # Array of Queue objects
      @all_stage_queues = all_stage_queues    # Hash of all queues for .to() method
      @runtime_edges = runtime_edges           # Track dynamic routing
      @items_produced = 0                      # Track count for stats
    end

    # Send item to all downstream stages
    def <<(item)
      @downstream_queues.each { |queue| queue << item }
      @items_produced += 1
      self
    end

    # Magic sauce: explicit routing to specific stage
    # Returns a new OutputQueue that routes only to that stage
    def to(target_stage)
      target_queue = @all_stage_queues[target_stage]
      raise ArgumentError, "Unknown target stage: #{target_stage}" unless target_queue

      # Track this as a runtime edge for END signal handling
      @runtime_edges[@stage_name].add(target_stage)

      # Return new OutputQueue that only routes to this target
      # Share the same items_produced counter so we don't double-count
      OutputQueue.new(@stage_name, [target_queue], @all_stage_queues, @runtime_edges).tap do |new_queue|
        new_queue.instance_variable_set(:@items_produced, @items_produced)
      end
    end
  end
end

