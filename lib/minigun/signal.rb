# frozen_string_literal: true

module Minigun
  # Base class for all pipeline queue signals
  # Queue signals are special marker objects that flow through queues to coordinate pipeline state
  class QueueSignal
  end

  # Signal indicating one upstream source has completed
  # Flows through raw queues, consumed by InputQueue wrapper
  class EndOfSource < QueueSignal
    attr_reader :source

    def initialize(source:)
      @source = source
    end

    def to_s
      "EndOfSource(#{@source})"
    end

    def inspect
      to_s
    end

    # Factory method for consistency with old API
    def self.from(source:)
      new(source: source)
    end
  end

  # Signal indicating all upstream sources for a stage have completed
  # Created by InputQueue wrapper when all expected sources send EndOfSource
  # This is a singleton per stage for efficiency
  class EndOfStage < QueueSignal
    attr_reader :stage_name

    def self.instance(stage_name)
      @instances ||= {}
      @instances[stage_name] ||= new(stage_name)
    end

    def initialize(stage_name)
      @stage_name = stage_name
    end

    def to_s
      "EndOfStage(#{@stage_name})"
    end

    def inspect
      to_s
    end
  end
end

