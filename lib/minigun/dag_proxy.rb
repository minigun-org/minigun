# frozen_string_literal: true

module Minigun
  # Proxy for DAG that resolves stage names to IDs before calling DAG methods
  # This allows tests to continue using names while DAG internally uses IDs
  class DAGProxy
    def initialize(pipeline)
      @pipeline = pipeline
      @dag = DAG.new
    end

    def downstream(identifier)
      id = resolve_to_id(identifier)
      result_ids = @dag.downstream(id)
      # Convert IDs back to names for test compatibility
      result_ids.map { |result_id|
        @pipeline.task.find_stage(result_id)&.name || result_id
      }
    end

    def upstream(identifier)
      id = resolve_to_id(identifier)
      result_ids = @dag.upstream(id)
      # Convert IDs back to names for test compatibility
      result_ids.map { |result_id|
        @pipeline.task.find_stage(result_id)&.name || result_id
      }
    end

    def terminal?(identifier)
      id = resolve_to_id(identifier)
      @dag.terminal?(id)
    end

    def add_node(identifier)
      id = resolve_to_id(identifier)
      @dag.add_node(id)
    end

    def add_edge(from_identifier, to_identifier)
      from_id = resolve_to_id(from_identifier)
      to_id = resolve_to_id(to_identifier)
      @dag.add_edge(from_id, to_id)
    end

    def remove_edge(from_identifier, to_identifier)
      from_id = resolve_to_id(from_identifier)
      to_id = resolve_to_id(to_identifier)
      @dag.remove_edge(from_id, to_id)
    end

    def nodes
      # Convert IDs back to names for test compatibility
      @dag.nodes.map { |id|
        @pipeline.task.find_stage(id)&.name || id
      }
    end

    def edges
      @dag.edges
    end

    def reverse_edges
      @dag.reverse_edges
    end

    def validate!
      @dag.validate!
    end

    def topological_sort
      @dag.topological_sort
    end

    def siblings(identifier)
      id = resolve_to_id(identifier)
      result_ids = @dag.siblings(id)
      # Convert IDs back to names for test compatibility
      result_ids.map { |result_id|
        @pipeline.task.find_stage(result_id)&.name || result_id
      }
    end

    def fan_out_siblings?(identifier1, identifier2)
      id1 = resolve_to_id(identifier1)
      id2 = resolve_to_id(identifier2)
      @dag.fan_out_siblings?(id1, id2)
    end

    def would_create_cycle?(from_identifier, to_identifier)
      from_id = resolve_to_id(from_identifier)
      to_id = resolve_to_id(to_identifier)
      @dag.would_create_cycle?(from_id, to_id)
    end

    # Delegate all other methods directly to DAG
    def method_missing(method, *args, &block)
      @dag.send(method, *args, &block)
    end

    def respond_to_missing?(method, include_private = false)
      @dag.respond_to?(method, include_private) || super
    end

    private

    def resolve_to_id(identifier)
      return identifier if identifier.nil?
      @pipeline.normalize_to_id(identifier)
    end
  end
end
