# frozen_string_literal: true

module Minigun
  # Pipeline represents a single data processing pipeline with stages
  # A Pipeline can be standalone or part of a multi-pipeline Task
  class Pipeline
    attr_reader :name, :config, :stages, :hooks, :dag, :output_queues, :stage_order, :stats,
                :context, :stage_hooks, :stage_input_queues, :runtime_edges, :input_queues, :task

    def initialize(task, name, config = {}, stages: nil, hooks: nil, stage_hooks: nil, dag: nil, stage_order: nil, stats: nil)
      @task = task
      @name = name
      @config = {
        max_threads: config[:max_threads] || 5,
        max_processes: config[:max_processes] || 2,
        max_retries: config[:max_retries] || 3,
        use_ipc: config[:use_ipc] || false
      }

      @stages = stages || {} # { stage_name => Stage }

      # Pipeline-level hooks (run once per pipeline)
      @hooks = hooks || {
        before_run: [],
        after_run: [],
        before_fork: [],
        after_fork: []
      }

      # Stage-specific hooks (run per stage execution)
      @stage_hooks = stage_hooks || {
        before: {},   # { stage_name => [blocks] }
        after: {},    # { stage_name => [blocks] }
        before_fork: {},
        after_fork: {}
      }

      @dag = dag || DAG.new
      @stage_order = stage_order || []

      # Statistics tracking
      @stats = stats # Will be initialized in run() if nil
    end

    # Find a stage by ID or name
    def find_stage(identifier)
      # First try as ID
      stage = @stages[identifier]
      return stage if stage

      # Then try as name
      @stages.values.find { |s| s.name == identifier }
    end

    # Normalize a stage identifier (name or ID) to ID
    def normalize_to_id(identifier)
      return identifier if @stages.key?(identifier) # Already an ID

      # Try to find by name
      stage = find_stage(identifier)
      stage&.id || identifier # Return original if not found
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
    def add_stage(type, name, options = {}, &block)
      # Extract routing information
      to_targets = options.delete(:to)
      Array(to_targets).each { |target| @dag.add_edge(name, target) } if to_targets

      # Extract reverse routing (from:)
      from_sources = options.delete(:from)
      Array(from_sources).each { |source| @dag.add_edge(source, name) } if from_sources

      # Extract inline hook procs (Option 3)
      if (before_proc = options.delete(:before))
        add_stage_hook(:before, name, &before_proc)
      end

      if (after_proc = options.delete(:after))
        add_stage_hook(:after, name, &after_proc)
      end

      if (before_fork_proc = options.delete(:before_fork))
        add_stage_hook(:before_fork, name, &before_fork_proc)
      end

      if (after_fork_proc = options.delete(:after_fork))
        add_stage_hook(:after_fork, name, &after_fork_proc)
      end

      # Create stage instance
      stage = if type.is_a?(Class)
                # Custom stage class provided
                type.new(name: name, options: options)
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

      # Check for name collision
      raise Minigun::Error, "Stage name collision: '#{name}' is already defined in pipeline '#{@name}'" if @stages.key?(name)

      # Store stage by name
      @stages[name] = stage

      # Add to stage order and DAG
      @stage_order << name
      @dag.add_node(name)
    end

    # Reroute stages by modifying the DAG
    def reroute_stage(from_stage, to:)
      # Remove existing outgoing edges from this stage
      old_targets = @dag.downstream(from_stage).dup
      old_targets.each do |target|
        @dag.edges[from_stage].delete(target)
        @dag.reverse_edges[target].delete(from_stage)
      end

      # Add new edges
      Array(to).each do |target|
        @dag.add_edge(from_stage, target)
      end
    end

    # Add a pipeline-level hook
    def add_hook(type, &block)
      @hooks[type] ||= []
      @hooks[type] << block
    end

    # Add a stage-specific hook
    def add_stage_hook(type, stage_name, &block)
      @stage_hooks[type] ||= {}
      @stage_hooks[type][stage_name] ||= []
      @stage_hooks[type][stage_name] << block
    end

    # Execute stage-specific hooks
    def execute_stage_hooks(type, stage_name)
      hooks = @stage_hooks.dig(type, stage_name) || []
      hooks.each { |h| @context.instance_exec(&h) }
    end

    # Execute both pipeline-level and stage-specific hooks
    # Pipeline-level hooks are executed first, then stage-specific hooks
    def execute_fork_hooks(type, stage_name)
      # Execute pipeline-level hooks first
      (@hooks[type] || []).each { |h| @context.instance_exec(&h) }
      # Then execute stage-specific hooks
      execute_stage_hooks(type, stage_name)
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
      @stages.each_value do |stage|
        worker = Worker.new(self, stage, @config)
        worker.start
        @stage_threads << worker
      end

      # Wait for all workers to finish
      @stage_threads.each(&:join)
    end

    # Build one input queue per stage (except producers)
    def build_stage_input_queues
      queues = {}

      @stages.each do |stage_name, stage|
        # Skip autonomous stages - they don't have input queues
        next if stage.run_mode == :autonomous

        # Special case: :_entrance uses the parent pipeline's input queue
        if stage_name == :_entrance && @input_queues && @input_queues[:input]
          queues[stage_name] = @input_queues[:input]
          next
        end

        # Use stage's queue_size setting (bounded SizedQueue or unbounded Queue)
        size = stage.queue_size
        queues[stage_name] = if size.nil?
                               Queue.new # Unbounded queue
                             else
                               SizedQueue.new(size) # Bounded queue with backpressure
                             end
      end

      queues
    end

    # Insert RouterStage instances for fan-out patterns
    def insert_router_stages_for_fan_out
      stages_to_add = []
      dag_updates = []

      @stages.each do |stage_name, stage|
        downstream = @dag.downstream(stage_name)

        # Fan-out: stage has multiple downstream consumers
        next unless downstream.size > 1

        # Get explicit routing strategy from stage options, or default to :broadcast
        routing_strategy = stage.options[:routing] || :broadcast

        # Create the appropriate router subclass
        router_name = :"#{stage_name}_router"
        router_stage = if routing_strategy == :round_robin
                         RouterRoundRobinStage.new(self, router_name, nil, { targets: downstream.dup })
                       else
                         RouterBroadcastStage.new(self, router_name, nil, { targets: downstream.dup })
                       end
        stages_to_add << [router_name, router_stage]

        # Update DAG: stage -> router -> [downstream targets]
        dag_updates << {
          remove_edges: downstream.map { |target| [stage_name, target] },
          add_edge: [stage_name, router_name],
          add_router_edges: downstream.map { |target| [router_name, target] }
        }

        log_debug "[Pipeline:#{@name}] Inserting RouterStage '#{router_name}' (#{routing_strategy}) for fan-out: #{stage_name} -> #{downstream.join(', ')}"
      end

      # Apply DAG updates
      dag_updates.each do |update|
        update[:remove_edges].each { |(from, to)| @dag.remove_edge(from, to) }
        @dag.add_edge(update[:add_edge][0], update[:add_edge][1])
        update[:add_router_edges].each { |(from, to)| @dag.add_edge(from, to) }
      end

      # Add router stages to @stages
      stages_to_add.each do |name, stage|
        @stages[name] = stage
      end
    end

    def find_stage(name)
      @stages[name]
    end

    def terminal_stage?(stage_name)
      @dag.terminal?(stage_name)
    end

    def get_targets(stage_name)
      targets = @dag.downstream(stage_name)

      # If no targets and we have output queues, this is an output stage
      return [:output] if targets.empty? && !@output_queues.empty? && !terminal_stage?(stage_name)

      targets
    end

    # Helper methods to find stages by characteristics
    def find_producer
      @stages.values.find { |stage| stage.run_mode == :autonomous }
    end

    def find_all_producers
      @stages.values.select do |stage|
        if stage.run_mode == :composite
          # Composite stage is a producer if it has no upstream
          @dag.upstream(stage.name).empty?
        else
          stage.run_mode == :autonomous
        end
      end
    end

    private

    def build_dag_routing!
      # FIRST: Merge nested pipeline DAGs (recursively builds nested pipelines first)
      # This must happen before normalizing edges so nested stages are in the DAG
      @stages.each_value do |stage|
        puts "[DEBUG build_dag_routing] Checking stage #{stage.display_name}: is PipelineStage? #{stage.is_a?(PipelineStage)}"
        if stage.is_a?(PipelineStage) && stage.nested_pipeline
          puts "[DEBUG build_dag_routing] Merging nested pipeline for #{stage.display_name}"
          merge_nested_pipeline_into_dag(stage)
        end
      end

      # Resolve all pending edges (forward references) now that all stages exist
      # DAG should ONLY contain IDs - this resolves any names from forward references
      @dag.resolve_pending_edges!

      # Handle multiple producers specially - they should all connect to first non-producer
      handle_multiple_producers_routing!

      # Fill any remaining sequential gaps (handles fan-out, siblings, cycles)
      puts "[DEBUG] Before fill_sequential_gaps: edges = #{@dag.edges.inspect}"
      fill_sequential_gaps_by_definition_order!
      puts "[DEBUG] After fill_sequential_gaps: edges = #{@dag.edges.inspect}"

      # If this pipeline has input_queues (nested pipeline), add entrance distributor
      insert_entrance_distributor_for_inputs! if @input_queues && !@input_queues.empty?

      # If this pipeline has output_queues, add exit collector for terminal stages
      insert_exit_collector_for_outputs! if @output_queues && !@output_queues.empty?

      @dag.validate!
      validate_stages_exist!

      # Log DAG using display names for readability
      dag_display = @dag.topological_sort.map { |id| find_stage(id)&.display_name || id }.join(' -> ')
      log_debug "#{log_prefix} DAG: #{dag_display}"
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

          # Skip composite stages - they don't participate in sequential routing
          next if candidate_obj.run_mode == :composite

          # Found a valid non-producer stage
          next_stage_id = candidate_id
          next_stage_obj = candidate_obj
          break
        end

        # No valid next stage found
        next unless next_stage_id
        next unless next_stage_obj  # Make sure we found the stage object

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

    # Merge a nested pipeline's DAG into this pipeline's DAG
    # This allows parent pipelines to route directly to nested stages
    def merge_nested_pipeline_into_dag(pipeline_stage)
      nested_pipeline = pipeline_stage.nested_pipeline
      return unless nested_pipeline

      # First, recursively build the nested pipeline's DAG
      nested_pipeline.build_dag_routing!

      # Merge nodes (stage IDs) from nested pipeline into parent DAG
      nested_pipeline.dag.nodes.each do |nested_stage_id|
        @dag.add_node(nested_stage_id)
      end

      # Merge edges from nested pipeline into parent DAG
      nested_pipeline.dag.edges.each do |from_id, to_ids|
        to_ids.each do |to_id|
          @dag.add_edge(from_id, to_id)
        end
      end

      # Store reference to nested pipeline stages in parent
      nested_pipeline.stages.each do |nested_stage_id, nested_stage|
        @stages[nested_stage_id] = nested_stage
      end

      # Add nested stages to stage order (for topological sorting)
      nested_pipeline.stage_order.each do |stage_id|
        @stage_order << stage_id unless @stage_order.include?(stage_id)
      end

      log_debug "[Pipeline:#{@name}] Merged nested pipeline '#{nested_pipeline.name}' with #{nested_pipeline.stages.size} stages"
    end

    def insert_entrance_distributor_for_inputs!
      # Entrance stage is NO LONGER NEEDED with DAG-centric architecture
      # Parent DAG includes nested stages, so parent routes directly to them
      # This method is kept as a no-op for now in case we need special logic later
    end

    # Insert an exit collector stage that terminal stages drain into
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
