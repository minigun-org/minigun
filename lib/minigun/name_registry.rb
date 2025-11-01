# frozen_string_literal: true

require 'securerandom'

module Minigun
  # Global registry for managing stage names and IDs
  # Provides centralized ID generation and name resolution for stage identification
  class NameRegistry
    def initialize
      @stages_by_id = {}   # id => stage
      @stages_by_name = {} # name => stage (single stage per name for now)
      @mutex = Mutex.new
    end

    # Generate a unique ID for a stage
    def generate_id
      SecureRandom.hex(8)
    end

    # Register a stage with the registry (optional for now - backward compatible)
    # @param stage [Stage] The stage to register
    def register(stage)
      @mutex.synchronize do
        @stages_by_id[stage.id] = stage
        @stages_by_name[stage.name] = stage if stage.name
      end
    end

    # Find a stage by ID
    # @param id [String] The stage ID
    # @return [Stage, nil] The stage instance or nil if not found
    def find_by_id(id)
      @stages_by_id[id]
    end

    # Find stage by name
    # @param name [String, Symbol] The stage name
    # @return [Stage, nil] The stage instance or nil if not found
    def find_by_name(name)
      @stages_by_name[name]
    end

    # Check if a stage ID exists
    # @param id [String] The stage ID
    # @return [Boolean] True if the stage exists
    def stage_exists?(id)
      @stages_by_id.key?(id)
    end

    # Check if a stage name exists
    # @param name [String, Symbol] The stage name
    # @return [Boolean] True if the stage name exists
    def name_exists?(name)
      @stages_by_name.key?(name)
    end

    # Clear all registrations (useful for testing)
    def clear
      @mutex.synchronize do
        @stages_by_id.clear
        @stages_by_name.clear
      end
    end
  end
end

