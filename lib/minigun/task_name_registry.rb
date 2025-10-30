# frozen_string_literal: true

module Minigun
  # TaskNameRegistry manages stage name resolution across the entire task
  # Implements routing strategy: local neighbors -> children (deep) -> global
  class TaskNameRegistry
    def initialize(task)
      @task = task
      @global_name_to_ids = {} # { name_string => [id1, id2, ...] }
    end

    # Register a stage name globally (multiple stages can have same name)
    def register(name, id)
      return unless name
      normalized = normalize(name)
      @global_name_to_ids[normalized] ||= []
      @global_name_to_ids[normalized] << id unless @global_name_to_ids[normalized].include?(id)
    end

    # Normalize name to string
    def normalize(name)
      return nil if name.nil?
      name.to_s
    end

    # Find stage by name from a given pipeline's perspective
    # Uses routing strategy: local neighbors -> children -> global
    # Raises AmbiguousRoutingError if multiple matches at any level
    def find_from_pipeline(name, pipeline)
      return nil if name.nil?

      # 1. Check local neighbors (stages in this pipeline)
      local_ids = pipeline.name_registry.find_all_local(name)
      if local_ids.size > 1
        raise AmbiguousRoutingError, "Stage name '#{name}' is ambiguous - found #{local_ids.size} stages locally in pipeline '#{pipeline.name}'"
      end
      return @task.find_stage(local_ids.first) if local_ids.size == 1

      # 2. Check neighbor's children (deep search into nested pipelines)
      children_ids = find_all_in_children(pipeline, name)
      if children_ids.size > 1
        raise AmbiguousRoutingError, "Stage name '#{name}' is ambiguous - found #{children_ids.size} stages in nested pipelines"
      end
      return @task.find_stage(children_ids.first) if children_ids.size == 1

      # 3. Check global registry (ALL stages everywhere)
      global_ids = find_all_global(name)
      if global_ids.size > 1
        raise AmbiguousRoutingError, "Stage name '#{name}' is ambiguous - found #{global_ids.size} stages globally"
      end
      return @task.find_stage(global_ids.first) if global_ids.size == 1

      nil
    end

    # Find all stages with the given name in a pipeline's nested children (deep search)
    def find_all_in_children(pipeline, name)
      results = []

      pipeline.stages.each_value do |stage|
        next unless stage.run_mode == :composite
        next unless stage.respond_to?(:nested_pipeline) && stage.nested_pipeline

        # Check the nested pipeline's local registry
        nested_ids = stage.nested_pipeline.name_registry.find_all_local(name)
        results.concat(nested_ids)

        # Recurse into nested pipeline's children
        results.concat(find_all_in_children(stage.nested_pipeline, name))
      end

      results
    end

    # Find all stages with the given name globally (across entire task)
    def find_all_global(name)
      return [] unless name
      normalized = normalize(name)
      @global_name_to_ids[normalized] || []
    end

    # Get all global names (for debugging)
    def all_names
      @global_name_to_ids.keys
    end

    # Clear all registrations (for testing)
    def clear!
      @global_name_to_ids.clear
    end
  end
end

