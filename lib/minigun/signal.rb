# frozen_string_literal: true

module Minigun
  # Base class for all pipeline queue signals
  # Queue signals are special marker objects that flow through queues to coordinate pipeline state
  class QueueSignal
    def to_s
      'QueueSignal'
    end

    def inspect
      to_s
    end
  end

  # Signal indicating one upstream source has completed
  # Flows through raw queues, consumed by InputQueue wrapper
  class EndOfSource < QueueSignal
    attr_reader :source  # Now contains stage ID

    def initialize(source_id)
      @source = source_id
    end

    def to_s
      "EndOfSource(#{@source})"
    end
  end

  # Signal indicating all upstream sources for a stage have completed
  # Created by InputQueue wrapper when all expected sources send EndOfSource
  class EndOfStage < QueueSignal
    attr_reader :stage_id  # Changed from stage_name - now contains stage ID

    def initialize(stage_id)
      @stage_id = stage_id
    end

    def to_s
      "EndOfStage(#{@stage_id})"
    end
  end
end
