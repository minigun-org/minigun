# frozen_string_literal: true

require 'set'

module Minigun
  # Pipeline represents a single data processing pipeline with stages
  # A Pipeline can be standalone or part of a multi-pipeline Task
  class Pipeline
    attr_reader :name, :config, :hooks, :dag, :output_queues, :stage_order, :stats,
                :context, :stage_hooks, :stage_input_queues, :runtime_edges, :input_queues,
                :stages  # Raw hash: { stage_id => Stage }
    attr_accessor :task

    # Find a stage by name or ID from this pipeline's perspective
    # Uses scoped name resolution: local → children → global
    def find_stage(identifier)
      @task.find_stage(identifier, from_pipeline: self)
    end

    def initialize(task, name, config = {}, stages: nil, hooks: nil, stage_hooks: nil, dag: nil, stage_order: nil, stats: nil)
      @task = task
      @name = name
      @config = {
        max_threads: config[:max_threads] || 5,
        max_processes: config[:max_processes] || 2,
        max_retries: config[:max_retries] || 3,
        use_ipc: config[:use_ipc] || false
      }

      @stages = stages || {} # { stage_id => Stage } - stages indexed by ID internally

      # Pipeline-level hooks (run once per pipeline)
      @hooks = hooks || {
        before_run: [],
        after_run: [],
        before_fork: [],
        after_fork: []
      }

      # Stage-specific hooks (run per stage execution)
      @stage_hooks = stage_hooks || {
        before: {},   # { stage_id => [blocks] }
        after: {},    # { stage_id => [blocks] }
        before_fork: {},
        after_fork: {}
      }

      @dag = dag || DAG.new
      @stage_order = stage_order || []
      @pending_edges = [] # Store forward references (edges with names) until stages exist

      # Statistics tracking
      @stats = stats # Will be initialized in run() if nil
    end

    # Duplicate this pipeline for inheritance
    def dup
      Pipeline.new(
        @task,
        @name,
        @config.dup,
        stages: @stages.transform_values(&:dup), # Deep copy - dup each stage object
        hooks: {
          before_run: @hooks[:before_run].dup,
          after_run: @hooks[:after_run].dup,
          before_fork: @hooks[:before_fork].dup,
          after_fork: @hooks[:after_fork].dup
        },
        stage_hooks: {
          before: @stage_hooks[:before].transform_values(&:dup),
          after: @stage_hooks[:after].transform_values(&:dup),
          before_fork: @stage_hooks[:before_fork].transform_values(&:dup),
          after_fork: @stage_hooks[:after_fork].transform_values(&:dup)
        },
        dag: @dag.dup,
        stage_order: @stage_order.dup
      )
    end

    # Add a stage to this pipeline
    # type can be a Symbol (:producer, :consumer, etc.) or a custom Stage class
    # name is optional - if not provided, stage will only be identified by ID
    def add_stage(type, name = nil, options = {}, &block)
      # Create stage instance (stages will register in pipeline's namespace)
      stage = if type.is_a?(Class)
                # Custom stage class provided
                type.new(self, name, block, options)
              else
                # Extract stage_type from options if present (used by DSL)
                actual_type = options.delete(:stage_type) || type

                # Create appropriate stage subclass based on type symbol
                case actual_type
                when :producer
                  ProducerStage.new(self, name, block, options)
                when :processor, :consumer
                  ConsumerStage.new(self, name, block, options)
                when :stage
                  Stage.new(self, name, block, options)
                when :accumulator
                  AccumulatorStage.new(self, name, block, options)
                else
                  raise Minigun::Error, "Unknown stage type: #{actual_type}"
                end
              end

      stage_id = stage.id

      # Extract routing information (user supplies names, we resolve to IDs)
      # DAG should ONLY contain IDs - store forward references separately
      to_targets = options.delete(:to)
      if to_targets
        Array(to_targets).each do |target|
          target_id = resolve_stage_identifier(target)
          if target_id
            # Target exists - add edge with ID immediately
            @dag.add_edge(stage_id, target_id)
          else
            # Forward reference - store for later resolution during build_dag_routing!
            @pending_edges << [:to, stage_id, target]
          end
        end
      end

      # Extract reverse routing (from:)
      from_sources = options.delete(:from)
      if from_sources
        Array(from_sources).each do |source|
          source_id = resolve_stage_identifier(source)
          if source_id
            # Source exists - add edge with ID immediately
            @dag.add_edge(source_id, stage_id)
          else
            # Forward reference - store for later resolution during build_dag_routing!
            @pending_edges << [:from, source, stage_id]
          end
        end
      end

      # Extract inline hook procs (use stage ID for hooks)
      if (before_proc = options.delete(:before))
        add_stage_hook(:before, stage_id, &before_proc)
      end

      if (after_proc = options.delete(:after))
        add_stage_hook(:after, stage_id, &after_proc)
      end

      if (before_fork_proc = options.delete(:before_fork))
        add_stage_hook(:before_fork, stage_id, &before_fork_proc)
      end

      if (after_fork_proc = options.delete(:after_fork))
        add_stage_hook(:after_fork, stage_id, &after_fork_proc)
      end

      # Store stage by ID (not name)
      @stages[stage_id] = stage

      # Migrate hooks registered by name to stage ID (if stage has a name)
      # This handles hooks defined before stages in the DSL
      if stage.name
        [:before, :after, :before_fork, :after_fork].each do |hook_type|
          # Check both symbol and string forms of the name
          name_str = stage.name.to_s
          name_sym = stage.name.to_sym
          name_hooks = @stage_hooks.dig(hook_type, name_str) || @stage_hooks.dig(hook_type, name_sym)
          if name_hooks
            @stage_hooks[hook_type] ||= {}
            @stage_hooks[hook_type][stage_id] ||= []
            @stage_hooks[hook_type][stage_id].concat(name_hooks)
            @stage_hooks[hook_type].delete(name_str)
            @stage_hooks[hook_type].delete(name_sym)
          end
        end
      end

      # Note: Stage already registered its name in its constructor

      # Add to stage order by ID and DAG
      @stage_order << stage_id
      @dag.add_node(stage_id)
      
      # CRITICAL: If this is a PipelineStage, merge nested stages into parent DAG
      # This makes the DAG the single source of truth for all routing
      if stage.is_a?(PipelineStage) && stage.instance_variable_get(:@nested_pipeline)
        merge_nested_pipeline_into_dag(stage)
      end
    end

    # Resolve a stage identifier (name or ID) to an ID
    # Returns the ID if found, nil otherwise
    # Special case: :output is a marker for output queues, not a stage name
    # Uses hierarchical name resolution (local → parent → task-level)
    def resolve_stage_identifier(identifier)
      return nil unless identifier
      return nil if identifier == :output

      # Use hierarchical lookup from this pipeline's perspective
      stage = find_stage(identifier)
      stage&.id
    end

    # Normalize a stage identifier to ID: try to resolve, fallback to original
    # Simple pattern: resolve_stage_identifier(id) || id
    def normalize_to_id(identifier)
      return nil unless identifier
      resolve_stage_identifier(identifier) || identifier
    end

    # Reroute stages by modifying the DAG
    # from_stage and to can be names or IDs (will be resolved to IDs)
    def reroute_stage(from_stage, to:)
      from_id = normalize_to_id(from_stage)
      return unless from_id

      # Remove existing outgoing edges from this stage
      old_targets = @dag.downstream(from_id).dup
      old_targets.each do |target|
        @dag.edges[from_id].delete(target)
        @dag.reverse_edges[target].delete(from_id)
      end

      # Add new edges (resolve targets to IDs)
      Array(to).each do |target|
        target_id = normalize_to_id(target)
        @dag.add_edge(from_id, target_id) if target_id
      end
    end

    # Add a pipeline-level hook
    def add_hook(type, &block)
      @hooks[type] ||= []
      @hooks[type] << block
    end

    # Add a stage-specific hook
    # stage_identifier can be name or ID (will be resolved to ID)
    def add_stage_hook(type, stage_identifier, &block)
      stage_id = normalize_to_id(stage_identifier)
      @stage_hooks[type] ||= {}
      @stage_hooks[type][stage_id] ||= []
      @stage_hooks[type][stage_id] << block
    end

    # Execute stage-specific hooks
    # stage_identifier can be name or ID (will be resolved to ID)
    def execute_stage_hooks(type, stage_identifier)
      stage_id = normalize_to_id(stage_identifier)
      hooks = @stage_hooks.dig(type, stage_id) || []
      hooks.each { |h| @context.instance_exec(&h) }
    end

    # Execute both pipeline-level and stage-specific hooks
    # Pipeline-level hooks are executed first, then stage-specific hooks
    # stage_identifier can be name or ID (will be resolved to ID)
    def execute_fork_hooks(type, stage_identifier)
      # Execute pipeline-level hooks first
      (@hooks[type] || []).each { |h| @context.instance_exec(&h) }
      # Then execute stage-specific hooks
      execute_stage_hooks(type, stage_identifier)
    end

    # Run this pipeline
    def run(context, job_id: nil)
      @context = context
      @job_start = Time.now
      @job_id = job_id

      # Initialize statistics tracking
      @stats = AggregatedStats.new(@task, @name, @dag)
      @stats.start!

      log_debug "#{log_prefix} Starting"

      # Build and validate DAG routing
      build_dag_routing!

      # Run before_run hooks
      @hooks[:before_run].each { |h| context.instance_eval(&h) }

      # Execute the pipeline
      run_pipeline(context)

      @job_end = Time.now
      @stats.finish!

      log_debug "#{log_prefix} Finished in #{(@job_end - @job_start).round(2)}s"

      # Run after_run hooks
      @hooks[:after_run].each { |h| context.instance_eval(&h) }

      # Return produced count
      @stats.total_produced
    end

    # Main pipeline execution logic
    def run_pipeline(_context)
      # Insert router stages for fan-out
      insert_router_stages_for_fan_out

      # Create one input queue per stage (except producers)
      @stage_input_queues = build_stage_input_queues
      @produced_count = Concurrent::AtomicFixnum.new(0)
      @stage_threads = []

      # Track runtime edges (who sends to whom) for dynamic routing termination
      # Key: source stage, Value: Set of target stages
      @runtime_edges = Concurrent::Hash.new { |h, k| h[k] = Concurrent::Set.new }

      # Start unified workers for ALL stages (producers and consumers)
      # Include both local stages and nested pipeline stages (DAG-centric)
      @stages.each_value do |stage|
        worker = Worker.new(self, stage, @config)
        worker.start
        @stage_threads << worker
      end
      
      # Also create workers for nested pipeline stages
      # (they're in parent DAG and have queues, but not in @stages)
      @stages.each_value do |stage|
        next unless stage.run_mode == :composite
        next unless stage.respond_to?(:nested_pipeline) && stage.nested_pipeline
        
        nested_pipeline = stage.nested_pipeline
        nested_pipeline.stages.each_value do |nested_stage|
          worker = Worker.new(self, nested_stage, @config)
          worker.start
          @stage_threads << worker
        end
      end

      # Wait for all workers to finish
      @stage_threads.each(&:join)
    end

    # Build one input queue per stage (except producers)
    def build_stage_input_queues(visited_pipelines = Set.new)
      # Prevent infinite recursion
      return {} if visited_pipelines.include?(object_id)
      visited_pipelines.add(object_id)

      queues = {}


      # Create queue for every stage (DAG includes all stages, including nested)
      @stages.each do |stage_id, stage|
        # Skip autonomous stages - they don't have input queues
        next if stage.run_mode == :autonomous

        # Use stage's queue_size setting (bounded SizedQueue or unbounded Queue)
        size = stage.queue_size
        queues[stage_id] = if size.nil?
                             Queue.new # Unbounded queue
                           else
                             SizedQueue.new(size) # Bounded queue with backpressure
                           end
      end

      # Also create queues for nested pipeline stages
      # (they're in parent DAG but stage objects are owned by nested pipeline)
      @stages.each_value do |stage|
        next unless stage.run_mode == :composite
        next unless stage.respond_to?(:nested_pipeline) && stage.nested_pipeline

        nested_pipeline = stage.nested_pipeline
        nested_pipeline.stages.each do |nested_stage_id, nested_stage|
          # Skip if already created or autonomous
          next if queues.key?(nested_stage_id)
          next if nested_stage.run_mode == :autonomous

          size = nested_stage.queue_size
          queues[nested_stage_id] = if size.nil?
                                      Queue.new
                                    else
                                      SizedQueue.new(size)
                                    end
        end
      end

      queues
    end

    # Insert RouterStage instances for fan-out patterns
    def insert_router_stages_for_fan_out
      stages_to_add = []
      dag_updates = []

      @stages.each do |stage_id, stage|
        downstream_ids = @dag.downstream(stage_id) # DAG only contains IDs

        # Fan-out: stage has multiple downstream consumers
        next unless downstream_ids.size > 1

        # Get explicit routing strategy from stage options, or default to :broadcast
        routing_strategy = stage.options[:routing] || :broadcast

        # Create the appropriate router subclass (will register in this pipeline)
        # Router stages don't get names - they're identified by ID only
        router_stage = if routing_strategy == :round_robin
                         RouterRoundRobinStage.new(self, nil, nil, { targets: downstream_ids.dup })
                       else
                         RouterBroadcastStage.new(self, nil, nil, { targets: downstream_ids.dup })
                       end
        router_id = router_stage.id
        stages_to_add << [router_id, router_stage]

        # Update DAG: stage -> router -> [downstream targets] (all by ID)
        dag_updates << {
          remove_edges: downstream_ids.map { |target_id| [stage_id, target_id] },
          add_edge: [stage_id, router_id],
          add_router_edges: downstream_ids.map { |target_id| [router_id, target_id] }
        }

        # Log using display names for readability
        stage_display = stage.display_name
        downstream_display = downstream_ids.map { |id| @task.find_stage(id)&.display_name || id }.join(', ')
        router_display = router_stage.display_name
        log_debug "[Pipeline:#{@name}] Inserting RouterStage '#{router_display}' (#{routing_strategy}) for fan-out: #{stage_display} -> #{downstream_display}"
      end

      # Apply DAG updates
      dag_updates.each do |update|
        update[:remove_edges].each { |(from, to)| @dag.remove_edge(from, to) }
        @dag.add_edge(update[:add_edge][0], update[:add_edge][1])
        update[:add_router_edges].each { |(from, to)| @dag.add_edge(from, to) }
      end

      # Add router stages to @stages by ID (already registered in Task during initialization)
      stages_to_add.each do |stage_id, stage|
        @stages[stage_id] = stage
        @stage_order << stage_id
      end
    end

    # Find a stage by name or ID from this pipeline's perspective
    # Delegates to task registry with this pipeline as context
    def find_stage(identifier)
      return nil if identifier.nil?
      @task.find_stage(identifier, from_pipeline: self)
    end

    def terminal_stage?(stage_identifier)
      stage_id = normalize_to_id(stage_identifier)
      @dag.terminal?(stage_id)
    end

    def get_targets(stage_identifier)
      stage_id = normalize_to_id(stage_identifier)
      targets = @dag.downstream(stage_id)

      # If no targets and we have output queues, this is an output stage
      return [:output] if targets.empty? && !@output_queues.empty? && !terminal_stage?(stage_id)

      targets
    end

    # Helper method for tests: get downstream stages by name or ID
    # Returns IDs, but can also convert back to names for test compatibility
    def downstream(stage_identifier)
      stage_id = normalize_to_id(stage_identifier)
      @dag.downstream(stage_id)
    end

    # Merge a nested pipeline's stages and edges into this pipeline's DAG
    # This allows parent pipeline to route directly to nested stages
    def merge_nested_pipeline_into_dag(pipeline_stage)
      nested_pipeline = pipeline_stage.instance_variable_get(:@nested_pipeline)
      return unless nested_pipeline
      
      # Add all nested stages as nodes in parent DAG
      nested_pipeline.stages.each_key do |nested_stage_id|
        @dag.add_node(nested_stage_id)
      end
      
      # Merge nested pipeline's DAG edges into parent DAG
      nested_pipeline.dag.edges.each do |from_id, to_ids|
        to_ids.each do |to_id|
          @dag.add_edge(from_id, to_id)
        end
      end
      
      # Don't connect PipelineStage to nested stages automatically
      # Let explicit routing (to:, from:, output.to()) handle connections
    end
    
    # Merge a nested pipeline's stages and edges into this pipeline's DAG
    # This allows parent pipeline to route directly to nested stages
    def merge_nested_pipeline_into_dag(pipeline_stage)
      nested_pipeline = pipeline_stage.instance_variable_get(:@nested_pipeline)
      return unless nested_pipeline
      
      # Add all nested stages as nodes in parent DAG
      nested_pipeline.stages.each_key do |nested_stage_id|
        @dag.add_node(nested_stage_id)
      end
      
      # Merge nested pipeline's DAG edges into parent DAG
      nested_pipeline.dag.edges.each do |from_id, to_ids|
        to_ids.each do |to_id|
          @dag.add_edge(from_id, to_id)
        end
      end
      
      # Don't connect PipelineStage to nested stages automatically
      # Let user define routing via output.to() or explicit DAG edges
    end

    # Helper method for tests: get upstream stages by name or ID
    # Returns IDs, but can also convert back to names for test compatibility
    def upstream(stage_identifier)
      stage_id = normalize_to_id(stage_identifier)
      @dag.upstream(stage_id)
    end

    # Convert stage IDs to names for test assertions
    # Returns an array where each ID is converted to its stage name (or ID if no name)
    def ids_to_names(ids)
      Array(ids).map do |id|
        stage = @task.find_stage(id)
        stage&.name || id
      end
    end

    # Helper methods to find stages by characteristics
    def find_producer
      @stages.values.find { |stage| stage.run_mode == :autonomous }
    end

    def find_all_producers
      @stages.values.select do |stage|
        if stage.run_mode == :composite
          # Composite stage is a producer if it has no upstream
          @dag.upstream(stage.id).empty?
        else
          stage.run_mode == :autonomous
        end
      end
    end

    private

    def build_dag_routing!
      # Normalize all DAG edges: convert names to IDs (handles forward references)
      normalize_dag_edges!

      # Handle multiple producers specially - they should all connect to first non-producer
      handle_multiple_producers_routing!

      # Fill any remaining sequential gaps (handles fan-out, siblings, cycles)
      fill_sequential_gaps_by_definition_order!

      # If this pipeline has input_queues (nested pipeline), add entrance distributor
      insert_entrance_distributor_for_inputs! if @input_queues && !@input_queues.empty?

      # If this pipeline has output_queues, add exit collector for terminal stages
      insert_exit_collector_for_outputs! if @output_queues && !@output_queues.empty?

      @dag.validate!
      validate_stages_exist!

      # Log DAG using display names for readability
      dag_display = @dag.topological_sort.map { |id| @task.find_stage(id)&.display_name || id }.join(' -> ')
      log_debug "#{log_prefix} DAG: #{dag_display}"
    end

    # Resolve all pending edges (forward references) now that all stages exist
    # DAG should ONLY contain IDs - this resolves any names from forward references
    def normalize_dag_edges!
      @pending_edges.each do |direction, from_identifier, to_identifier|
        # Resolve the identifier that was a forward reference
        from_id = direction == :to ? from_identifier : resolve_stage_identifier(from_identifier)
        to_id = direction == :to ? resolve_stage_identifier(to_identifier) : to_identifier

        if from_id && to_id
          @dag.add_edge(from_id, to_id)
        else
          # If we can't resolve, that's an error - stage doesn't exist
          unresolved = from_id ? to_identifier : from_identifier
          raise Error, "Cannot resolve forward reference to stage: #{unresolved.inspect}"
        end
      end

      @pending_edges.clear
    end

    def validate_stages_exist!
      @dag.nodes.each do |node_id|
        stage = find_stage(node_id)
        unless stage
          raise Minigun::Error, "[Pipeline:#{@name}] Routing references non-existent stage ID '#{node_id}'"
        end
      end
    end

    def handle_multiple_producers_routing!
      producers = @stage_order.select { |stage_id| find_stage(stage_id)&.run_mode == :autonomous }

      # Each producer without explicit routing should connect to its next stage in definition order
      producers.each do |producer_id|
        # Skip if this producer already has explicit downstream edges
        next unless @dag.downstream(producer_id).empty?

        # Find the next non-autonomous stage after this producer
        producer_index = @stage_order.index(producer_id)
        next_stage_id = @stage_order[(producer_index + 1)..].find { |stage_id| find_stage(stage_id)&.run_mode != :autonomous }

        @dag.add_edge(producer_id, next_stage_id) if next_stage_id
      end
    end

    def fill_sequential_gaps_by_definition_order!
      # Then fill remaining sequential gaps
      @stage_order.each_with_index do |stage_id, index|
        # Skip if already has downstream edges
        next if @dag.downstream(stage_id).any?
        # Skip if this is the last stage
        next if index >= @stage_order.size - 1

        # Find the next non-producer stage
        next_stage_id = nil
        next_stage_obj = nil
        ((index + 1)...@stage_order.size).each do |next_index|
          candidate_id = @stage_order[next_index]
          candidate_obj = find_stage(candidate_id)

          # Skip if stage not found (shouldn't happen, but defensive)
          next unless candidate_obj

          # Skip autonomous stages
          next if candidate_obj.run_mode == :autonomous

          # Found a valid non-producer stage
          next_stage_id = candidate_id
          next_stage_obj = candidate_obj
          break
        end

        # No valid next stage found
        next unless next_stage_id
        next unless next_stage_obj  # Make sure we found the stage object

        # Skip if BOTH current and next are composite stages (isolated pipelines)
        current_stage = find_stage(stage_id)
        next unless current_stage  # Make sure current stage exists
        next if current_stage.run_mode == :composite && next_stage_obj.run_mode == :composite

        # Skip if this is a fan-out pattern (next_stage is a sibling)
        next if @dag.fan_out_siblings?(stage_id, next_stage_id)

        # Skip if any sibling already routes to next_stage
        siblings = @dag.siblings(stage_id)
        next if siblings.any? { |sib_id| @dag.downstream(sib_id).include?(next_stage_id) }

        # Don't add edge if it would create a cycle
        next if @dag.would_create_cycle?(stage_id, next_stage_id)

        @dag.add_edge(stage_id, next_stage_id)
      end
    end

    # Insert an entrance distributor stage for nested pipelines
    # This receives items from the parent pipeline and distributes to entry stages
    def insert_entrance_distributor_for_inputs!
      # Entrance stage is NO LONGER NEEDED with DAG-centric architecture
      # Parent DAG includes nested stages, so parent routes directly to them
      # This method is kept as a no-op for now in case we need special logic later
    end

    # Insert an :_exit collector stage that terminal stages drain into
    # This allows nested pipelines to send their outputs to the parent pipeline
    def insert_exit_collector_for_outputs!
      # Find terminal stages (stages with no downstream)
      terminal_stage_ids = @stages.keys.select { |stage_id| @dag.terminal?(stage_id) }
      return if terminal_stage_ids.empty?

      # Create a consumer stage that forwards items to @output_queues[:output]
      # The block receives (item, output) but we ignore output and use @output_queues directly
      # No name - exit stage is identified by ID only
      parent_output = @output_queues[:output]
      exit_block = proc do |item, _stage_output|
        parent_output << item if parent_output
      end
      exit_stage = Minigun::ConsumerStage.new(self, nil, exit_block, {})
      exit_id = exit_stage.id

      # Add the exit stage to the pipeline by ID
      @stages[exit_id] = exit_stage
      @stage_order << exit_id
      @dag.add_node(exit_id)

      # Connect terminal stages to exit (all by ID)
      terminal_stage_ids.each do |terminal_stage_id|
        @dag.add_edge(terminal_stage_id, exit_id)
      end

      # Note: input queue for exit will be created automatically by build_stage_input_queues

      # Log using display names for readability
      terminal_display = terminal_stage_ids.map { |id| @task.find_stage(id)&.display_name || id }.join(', ')
      log_debug "[Pipeline:#{@name}] Added exit collector '#{exit_stage.display_name}' for terminal stages: #{terminal_display}"
    end

    def log_prefix
      if @job_id
        "[Job:#{@job_id}][Pipeline:#{@name}]"
      else
        "[Pipeline:#{@name}]"
      end
    end

    def log_debug(msg)
      Minigun.logger.debug(msg)
    end

    def log_error(msg)
      Minigun.logger.error(msg)
    end
  end
end
