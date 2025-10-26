# frozen_string_literal: true

module Minigun
  module Execution
    # Analyzes a pipeline's DAG and determines execution contexts and affinity
    class ExecutionPlan
      attr_reader :dag, :stages, :config

      def initialize(dag, stages, config)
        @dag = dag
        @stages = stages
        @config = config
        @stage_contexts = {}  # stage_name => context_type
        @stage_affinity = {}  # stage_name => parent_stage_name (or nil)
      end

      # Analyze DAG and assign execution contexts
      def plan!
        # 1. Identify producers (no upstream) - always get their own context
        producers.each do |stage|
          assign_context(stage, context_type_for(stage), affinity: nil)
        end

        # 2. Topologically sort and assign contexts
        @dag.topological_sort.each do |stage_name|
          next if @stage_contexts.key?(stage_name)

          stage = @stages[stage_name]
          next unless stage  # Skip if stage doesn't exist (e.g., :_input node)

          upstream = @dag.upstream(stage_name)

          # Determine affinity
          affinity = determine_affinity(stage, upstream)

          # Determine context type
          context_type = if affinity
            # Execute in same context as affinity parent
            @stage_contexts[affinity]
          else
            # Execute in own context
            context_type_for(stage)
          end

          assign_context(stage, context_type, affinity: affinity)
        end

        self
      end

      # Get context type for a stage
      def context_for(stage_name)
        @stage_contexts[stage_name] || :thread
      end

      # Get affinity parent for a stage (or nil if independent)
      def affinity_for(stage_name)
        @stage_affinity[stage_name]
      end

      # Should this stage run in same context as its source?
      def colocated?(stage_name, source_name)
        @stage_affinity[stage_name] == source_name
      end

      # Get all unique context types used in this plan
      def context_types
        @stage_contexts.values.uniq
      end

      # Get stages grouped by affinity
      def affinity_groups
        groups = Hash.new { |h, k| h[k] = [] }
        @stages.each_key do |stage_name|
          affinity = @stage_affinity[stage_name]
          groups[affinity] << stage_name
        end
        groups
      end

      # Get independent stages (no affinity parent)
      def independent_stages
        affinity_groups[nil]
      end

      # Get colocated stages (have affinity parent)
      def colocated_stages
        affinity_groups.reject { |k, _| k.nil? }
      end

      private

      def assign_context(stage, context_type, affinity:)
        @stage_contexts[stage.name] = context_type
        @stage_affinity[stage.name] = affinity
      end

      def context_type_for(stage)
        # Check stage's execution context
        exec_ctx = stage.execution_context

        if exec_ctx
          return exec_ctx[:type] || :thread
        end

        # Default based on config
        @config[:default_context] || :thread
      end

      def determine_affinity(stage, upstream_stages)
        # Rules for affinity (colocated execution):
        # 1. If single upstream and it's a producer -> colocate
        # 2. If multiple upstream -> independent (needs own context)
        # 3. If upstream is accumulator -> always independent
        # 4. If stage requests specific strategy -> independent
        # 5. If stage uses spawn strategy -> independent (pooled)

        return nil if upstream_stages.size != 1

        upstream_name = upstream_stages.first
        upstream_stage = @stages[upstream_name]

        return nil unless upstream_stage  # Skip if upstream is special node

        # Don't colocate if stage has explicit execution context
        return nil if stage.execution_context

        # Don't colocate with PipelineStages (they run independently)
        return nil if upstream_stage.is_a?(Minigun::PipelineStage)

        # Colocate with upstream for efficiency
        upstream_name
      end

      def producers
        @stages.values.select do |stage|
          upstream = @dag.upstream(stage.name)
          upstream.empty? || upstream == [:_input]
        end
      end
    end
  end
end

