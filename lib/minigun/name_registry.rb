# frozen_string_literal: true

module Minigun
  # Unified registry for stage management across the entire Task hierarchy
  # Handles both ID-based (fast) and name-based (scoped) lookups
  #
  # Design principles:
  # 1. Stages are ALWAYS identified by ID internally (fast, unambiguous)
  # 2. Names are optional and scoped to pipelines (user-friendly)
  # 3. Name resolution follows: local → children → global
  # 4. Ambiguous names raise errors at resolution time
  class NameRegistry
    attr_reader :task

    def initialize(task)
      @task = task
      @stages_by_id = {}              # { id => Stage } - primary registry
      @global_names = Hash.new { |h, k| h[k] = [] }  # { name_string => [id1, id2, ...] }
      @pipeline_names = {}            # { pipeline_name => { name_string => id } }
      @stage_counter = 0
    end

    # Generate a short, readable stage ID
    def generate_id
      @stage_counter += 1
      "s#{@stage_counter}"
    end

    # Register a stage (called from Stage#initialize)
    # This is the ONLY registration method - handles both ID and name atomically
    def register(stage, pipeline_name: nil)
      id = stage.id
      name = stage.name

      # 1. Register by ID (required, must be unique)
      if @stages_by_id.key?(id)
        raise Error, "Stage ID collision: '#{id}' is already registered"
      end
      @stages_by_id[id] = stage

      # 2. Register by name if provided
      return unless name && name != :output

      name_str = normalize_name(name)

      # Register in pipeline's local namespace (must be unique per pipeline)
      if pipeline_name
        @pipeline_names[pipeline_name] ||= {}
        if @pipeline_names[pipeline_name].key?(name_str)
          existing_id = @pipeline_names[pipeline_name][name_str]
          raise StageNameConflict,
                "Stage name '#{name}' already exists in pipeline '#{pipeline_name}' " \
                "(existing: #{existing_id}, new: #{id})"
        end
        @pipeline_names[pipeline_name][name_str] = id
      end

      # Register in global namespace (multiple stages can have same name)
      @global_names[name_str] << id unless @global_names[name_str].include?(id)
    end

    # Find stage by ID (fast path, always unambiguous)
    def find_by_id(id)
      @stages_by_id[id]
    end

    # Find stage by name from a specific pipeline's perspective
    # Uses 3-level routing strategy: local → children → global
    # Raises AmbiguousRoutingError if multiple matches found at any level
    def find_by_name(name, from_pipeline:)
      return nil unless name

      name_str = normalize_name(name)
      pipeline_name = from_pipeline.name

      # Level 1: Local neighbors (stages in same pipeline)
      if @pipeline_names[pipeline_name]&.key?(name_str)
        local_id = @pipeline_names[pipeline_name][name_str]
        return @stages_by_id[local_id]
      end

      # Level 2: Children (stages in nested pipelines)
      children_ids = find_in_children(from_pipeline, name_str)
      if children_ids.size > 1
        raise AmbiguousRoutingError,
              "Stage name '#{name}' is ambiguous - found #{children_ids.size} matches in nested pipelines"
      end
      return @stages_by_id[children_ids.first] if children_ids.size == 1

      # Level 3: Global (any stage anywhere)
      global_ids = @global_names[name_str]
      if global_ids.size > 1
        raise AmbiguousRoutingError,
              "Stage name '#{name}' is ambiguous - found #{global_ids.size} matches globally: #{global_ids.join(', ')}"
      end
      return @stages_by_id[global_ids.first] if global_ids.size == 1

      nil
    end

    # Find stage by identifier (ID or name) from a pipeline's perspective
    # This is the main entry point for all lookups
    def find(identifier, from_pipeline:)
      return nil unless identifier

      # Fast path: Try ID lookup first
      stage = find_by_id(identifier)
      return stage if stage

      # Slow path: Try name lookup with scoping
      find_by_name(identifier, from_pipeline: from_pipeline)
    end

    # Get all stages (for debugging/inspection)
    def all_stages
      @stages_by_id.values
    end

    # Get all stage IDs (for debugging/inspection)
    def all_ids
      @stages_by_id.keys
    end

    # Get all registered names (for debugging/inspection)
    def all_names
      @global_names.keys
    end

    # Clear everything (for testing)
    def clear!
      @stages_by_id.clear
      @global_names.clear
      @pipeline_names.clear
      @stage_counter = 0
    end

    private

    # Normalize name to string (symbols and strings both work)
    def normalize_name(name)
      return nil if name.nil?
      name.to_s
    end

    # Recursively find all stages with given name in pipeline's nested children
    def find_in_children(pipeline, name_str)
      results = []

      pipeline.stages.each_value do |stage|
        next unless stage.run_mode == :composite
        next unless stage.respond_to?(:nested_pipeline) && stage.nested_pipeline

        nested_pipeline = stage.nested_pipeline
        nested_name = nested_pipeline.name

        # Check nested pipeline's local namespace
        if @pipeline_names[nested_name]&.key?(name_str)
          results << @pipeline_names[nested_name][name_str]
        end

        # Recurse into nested pipeline's children
        results.concat(find_in_children(nested_pipeline, name_str))
      end

      results
    end
  end
end
