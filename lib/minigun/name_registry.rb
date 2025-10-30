# frozen_string_literal: true

module Minigun
  # NameRegistry manages stage name-to-ID mappings within a pipeline scope
  # Supports hierarchical lookup (local → parent → task-level)
  class NameRegistry
    attr_reader :parent

    def initialize(parent: nil)
      @names = {} # { normalized_name (string) => stage_id }
      @parent = parent # Parent pipeline's registry (for hierarchical lookup)
    end

    # Normalize stage name to string (symbols and strings both supported)
    # Returns nil if name is nil
    def normalize(name)
      return nil if name.nil?
      name.to_s
    end

    # Register a stage name at this level
    # Raises StageNameConflict if name already exists at this level
    def register(name, stage_id, context_name: nil)
      return if name.nil?

      normalized = normalize(name)

      if @names.key?(normalized)
        existing_id = @names[normalized]
        context = context_name ? " in pipeline '#{context_name}'" : ""
        raise StageNameConflict, "Stage name '#{name}' is already registered#{context} (existing ID: #{existing_id}, new ID: #{stage_id})"
      end

      @names[normalized] = stage_id
    end

    # Look up a stage ID by name (local only, no hierarchy)
    def lookup(name)
      return nil if name.nil?
      normalized = normalize(name)
      @names[normalized]
    end

    # Check if a name is registered locally
    def registered?(name)
      return false if name.nil?
      normalized = normalize(name)
      @names.key?(normalized)
    end

    # Find a stage by name using scoped lookup with ambiguity checking:
    # This is called by Pipeline which implements the routing strategy:
    # 1. Local neighbors (stages in same pipeline)
    # 2. Neighbor's children (deep search into nested pipelines)
    # 3. Global registry (task-level)
    # 
    # This registry only handles local lookups - Pipeline orchestrates the strategy
    def find_local(name)
      return nil if name.nil?
      lookup(name)
    end

    # Get all local stage IDs with the given name (for ambiguity detection)
    # Returns array of stage_ids
    def find_all_local(name)
      return [] if name.nil?
      normalized = normalize(name)
      @names[normalized] ? [@names[normalized]] : []
    end

    # Get all registered names (for debugging)
    def all_names
      @names.keys
    end

    # Clear all registrations (for testing/reset)
    def clear!
      @names.clear
    end
  end
end

