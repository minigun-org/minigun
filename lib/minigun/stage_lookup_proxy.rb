# frozen_string_literal: true

module Minigun
  # Proxy object for Pipeline#stages that supports both ID and name lookups
  # Internally stages are stored by ID, but this allows backward-compatible access by name
  class StageLookupProxy
    include Enumerable

    def initialize(stages_by_id, task)
      @stages_by_id = stages_by_id
      @task = task
    end

    def [](key)
      # Try to find stage - resolve name to ID if needed
      stage = @task.find_stage(key)
      return stage if stage

      # Fallback: try direct lookup (might be ID that find_stage didn't resolve)
      @stages_by_id[key]
    end

    def key?(key)
      !self[key].nil?
    end

    def keys
      @stages_by_id.keys
    end

    def values
      @stages_by_id.values
    end

    def each(&block)
      @stages_by_id.each(&block)
    end

    def size
      @stages_by_id.size
    end

    def empty?
      @stages_by_id.empty?
    end

    def select(&block)
      @stages_by_id.select(&block)
    end

    def transform_values(&block)
      @stages_by_id.transform_values(&block)
    end

    def ==(other)
      @stages_by_id == other
    end

    def to_h
      @stages_by_id.dup
    end

    # Support assignment by ID (for internal use)
    def []=(key, value)
      # Try to resolve name to ID, fallback to key if not found
      stage = @task.find_stage(key)
      id = stage ? stage.id : key
      @stages_by_id[id] = value
    end
  end
end

