# frozen_string_literal: true

require 'securerandom'

module Minigun
  # Global registry for managing stage names and IDs across pipelines
  # Provides atomic ID generation and name resolution for robust stage identification
  class NameRegistry
    def initialize
      @stages = {} # id => stage
      @names = {}  # pipeline_name => { name => [stage_ids] }
      @mutex = Mutex.new
    end

    # Generate a unique ID for a stage
    def generate_id
      SecureRandom.hex(8)
    end

    # Register a stage with the registry
    # @param stage [Stage] The stage to register
    # @param pipeline_name [String, Symbol] Name of the pipeline this stage belongs to
    def register(stage, pipeline_name:)
      @mutex.synchronize do
        @stages[stage.id] = stage
        @names[pipeline_name] ||= {}
        @names[pipeline_name][stage.name] ||= []
        @names[pipeline_name][stage.name] << stage.id unless @names[pipeline_name][stage.name].include?(stage.id)
      end
    end

    # Find a stage by ID
    # @param id [String] The stage ID
    # @return [Stage, nil] The stage instance or nil if not found
    def find_by_id(id)
      @stages[id]
    end

    # Find stages by name within a pipeline
    # @param name [String, Symbol] The stage name
    # @param pipeline_name [String, Symbol] The pipeline name
    # @return [Array<Stage>] Array of matching stages
    def find_by_name(name, pipeline_name:)
      ids = @mutex.synchronize { @names.dig(pipeline_name, name) } || []
      ids.map { |id| @stages[id] }.compact
    end

    # Get all stage IDs for a pipeline
    # @param pipeline_name [String, Symbol] The pipeline name
    # @return [Array<String>] Array of stage IDs
    def stage_ids_for_pipeline(pipeline_name)
      @mutex.synchronize { @names[pipeline_name]&.values&.flatten || [] }
    end

    # Get all stage names for a pipeline
    # @param pipeline_name [String, Symbol] The pipeline name
    # @return [Array<String, Symbol>] Array of stage names
    def stage_names_for_pipeline(pipeline_name)
      @mutex.synchronize { @names[pipeline_name]&.keys || [] }
    end

    # Check if a stage ID exists
    # @param id [String] The stage ID
    # @return [Boolean] True if the stage exists
    def stage_exists?(id)
      @stages.key?(id)
    end

    # Check if a stage name exists in a pipeline
    # @param name [String, Symbol] The stage name
    # @param pipeline_name [String, Symbol] The pipeline name
    # @return [Boolean] True if the stage name exists
    def name_exists?(name, pipeline_name:)
      @mutex.synchronize { @names.dig(pipeline_name, name)&.any? }
    end

    # Clear all registrations (useful for testing)
    def clear
      @mutex.synchronize do
        @stages.clear
        @names.clear
      end
    end
  end
end
