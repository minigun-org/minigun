# frozen_string_literal: true

module Minigun
  # Message represents a control signal in the pipeline transport layer
  # Data items flow unwrapped; only control signals are wrapped
  class Message
    attr_reader :type, :source

    def initialize(type:, source:)
      @type = type
      @source = source
    end

    def end_of_stream?
      @type == :end
    end

    def self.end_signal(source:)
      new(type: :end, source: source)
    end
  end
end

