# frozen_string_literal: true

module Minigun
  module Execution
    # Orchestrates pipeline execution using ExecutionPlan and ContextPools
    class ExecutionOrchestrator
      attr_reader :pipeline, :plan

      def initialize(pipeline)
        @pipeline = pipeline
        @pools = {}
        @contexts = {}
        @plan = nil
      end

      # Execute the pipeline with the orchestrator
      def execute(context)
        # Create execution plan
        @plan = ExecutionPlan.new(
          @pipeline.dag,
          @pipeline.stages,
          @pipeline.config
        ).plan!

        # Create context pools for each type
        @plan.context_types.each do |type|
          @pools[type] = ContextPool.new(
            type: type,
            max_size: max_size_for(type)
          )
        end

        # Execute according to plan
        execute_plan(context)

        # Wait for completion
        @pools.values.each(&:join_all)
      ensure
        # Cleanup
        @pools.values.each(&:terminate_all)
      end

      private

      def execute_plan(context)
        # For now, use the existing pipeline execution
        # In future, we can optimize by:
        # 1. Grouping colocated stages
        # 2. Running them sequentially in same context
        # 3. Only using queues between independent stages

        # This is a placeholder that delegates to existing logic
        # Full implementation would rewrite pipeline execution
        @pipeline.send(:run_normal_pipeline, context)
      end

      def max_size_for(type)
        case type
        when :thread
          @pipeline.config[:max_threads] || 5
        when :fork
          @pipeline.config[:max_processes] || 2
        when :ractor
          @pipeline.config[:max_ractors] || 4
        when :inline
          1
        else
          5
        end
      end

      # Future: Execute colocated stages in same context
      def execute_colocated(stages, parent_context, user_context)
        # All stages run sequentially in parent's context
        # No queues needed - direct function calls
        # Communication via local variables

        current_items = []

        stages.each do |stage_name|
          stage = @pipeline.stages[stage_name]
          next unless stage

          next_items = []
          current_items.each do |item|
            results = stage.execute_with_emit(user_context, item)
            next_items.concat(results)
          end
          current_items = next_items
        end

        current_items
      end

      # Future: Execute independent stages in separate contexts
      def execute_independent(stage, user_context)
        context_type = @plan.context_for(stage.name)
        pool = @pools[context_type]

        exec_context = pool.acquire("#{@pipeline.name}:#{stage.name}")
        @contexts[stage.name] = exec_context

        exec_context.execute do
          # Execute stage with proper setup
          execute_stage_in_context(stage, user_context)
        end
      end

      def execute_stage_in_context(stage, user_context)
        # Setup emit method
        emitted_items = []
        user_context.define_singleton_method(:emit) do |item|
          emitted_items << item
        end

        # Execute stage logic
        if stage.block
          user_context.instance_eval(&stage.block)
        end

        emitted_items
      end
    end
  end
end

