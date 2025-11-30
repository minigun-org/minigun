# frozen_string_literal: true

module Minigun
  # All Minigun errors are namespaced under Minigun::Errors
  module Errors
    # Base error class for all Minigun errors.
    # All Minigun-specific errors inherit from this class.
    #
    # @example Catching all Minigun errors
    #   begin
    #     pipeline.run
    #   rescue Minigun::Errors::BaseError => e
    #     logger.error "Pipeline failed: #{e.message}"
    #   end
    class BaseError < StandardError
      # @return [Hash] Additional context about the error
      attr_reader :context

      # @param message [String, nil] Error message
      # @param context [Hash] Additional context key-value pairs
      def initialize(message = nil, **context)
        @context = context
        super(message)
      end

      # Returns the error message with context details appended.
      # @return [String] Detailed error message
      def detailed_message(...)
        return message if context.empty?

        details = context.map { |k, v| "#{k}=#{v.inspect}" }.join(', ')
        "#{message} (#{details})"
      end
    end

    # ============================================
    # Configuration Errors (DSL/setup time)
    # ============================================

    # Base class for configuration-time errors.
    # These errors occur during pipeline definition, before execution.
    class ConfigurationError < BaseError; end

    # Raised when a stage name conflicts with another at the same pipeline level.
    #
    # @example
    #   pipeline do
    #     processor :transform do |item, output|
    #       output << item
    #     end
    #     processor :transform do |item, output|  # Raises StageNameConflict
    #       output << item
    #     end
    #   end
    class StageNameConflict < ConfigurationError
      # @return [Symbol, String, nil] The conflicting stage name
      attr_reader :stage_name

      # @return [String, nil] The pipeline where the conflict occurred
      attr_reader :pipeline_name

      # @param message [String, nil] Custom error message
      # @param stage_name [Symbol, String, nil] The conflicting stage name
      # @param pipeline_name [String, nil] The pipeline name
      def initialize(message = nil, stage_name: nil, pipeline_name: nil)
        @stage_name = stage_name
        @pipeline_name = pipeline_name
        msg = message || "Stage name '#{stage_name}' already exists in pipeline '#{pipeline_name}'"
        super(msg, stage_name: stage_name, pipeline_name: pipeline_name)
      end
    end

    # Raised when routing cannot resolve an ambiguous stage name.
    # This occurs when multiple stages share the same name in nested pipelines.
    #
    # @example
    #   pipeline do
    #     nested_pipeline :a do
    #       processor :transform do |item, output|
    #         output << item
    #       end
    #     end
    #     nested_pipeline :b do
    #       processor :transform do |item, output|
    #         output << item
    #       end
    #     end
    #     # Routing to :transform is ambiguous - exists in both :a and :b
    #   end
    class AmbiguousRouting < ConfigurationError
      # @return [Symbol, String, nil] The ambiguous stage name
      attr_reader :stage_name

      # @return [Array<String>] List of candidate stage paths
      attr_reader :candidates

      # @param message [String, nil] Custom error message
      # @param stage_name [Symbol, String, nil] The ambiguous stage name
      # @param candidates [Array<String>] List of matching stage paths
      def initialize(message = nil, stage_name: nil, candidates: [])
        @stage_name = stage_name
        @candidates = candidates
        msg = message || "Stage name '#{stage_name}' is ambiguous - found #{candidates.size} matches"
        super(msg, stage_name: stage_name, candidates: candidates)
      end
    end

    # Raised when an invalid option value is provided.
    #
    # @example
    #   in_ipc_forks(4, restart_policy: :invalid) do  # Raises InvalidOption
    #     processor :work do |item, output|
    #       output << item
    #     end
    #   end
    class InvalidOption < ConfigurationError
      # @return [Symbol, String, nil] The option name
      attr_reader :option_name

      # @return [Object, nil] The invalid value provided
      attr_reader :value

      # @return [String, nil] Description of expected values
      attr_reader :expected

      # @param message [String, nil] Custom error message
      # @param option_name [Symbol, String, nil] The option name
      # @param value [Object, nil] The invalid value
      # @param expected [String, nil] Description of expected values
      def initialize(message = nil, option_name: nil, value: nil, expected: nil)
        @option_name = option_name
        @value = value
        @expected = expected
        msg = message || "Invalid #{option_name}: #{value.inspect}. Expected: #{expected}"
        super(msg, option_name: option_name, value: value, expected: expected)
      end
    end

    # ============================================
    # Pipeline Structure Errors
    # ============================================

    # Base class for pipeline structure errors.
    # These errors relate to the pipeline's DAG structure and routing.
    class PipelineError < BaseError
      # @return [String, nil] The pipeline name where the error occurred
      attr_reader :pipeline_name

      # @param message [String, nil] Custom error message
      # @param pipeline_name [String, nil] The pipeline name
      # @param context [Hash] Additional context
      def initialize(message = nil, pipeline_name: nil, **context)
        @pipeline_name = pipeline_name
        super(message, pipeline_name: pipeline_name, **context)
      end
    end

    # Raised when a cyclic dependency is detected in the pipeline DAG.
    #
    # @example
    #   pipeline do
    #     processor :a, routes_to: :b do |item, output|
    #       output << item
    #     end
    #     processor :b, routes_to: :a do |item, output|  # Raises CyclicDependency
    #       output << item
    #     end
    #   end
    class CyclicDependency < PipelineError
      # @return [Symbol, String, nil] The source stage of the edge causing the cycle
      attr_reader :from_stage

      # @return [Symbol, String, nil] The target stage of the edge causing the cycle
      attr_reader :to_stage

      # @param message [String, nil] Custom error message
      # @param pipeline_name [String, nil] The pipeline name
      # @param from_stage [Symbol, String, nil] Source stage
      # @param to_stage [Symbol, String, nil] Target stage
      def initialize(message = nil, pipeline_name: nil, from_stage: nil, to_stage: nil)
        @from_stage = from_stage
        @to_stage = to_stage
        msg = message || "Circular dependency detected: adding edge #{from_stage} -> #{to_stage} would create a cycle"
        super(msg, pipeline_name: pipeline_name, from_stage: from_stage, to_stage: to_stage)
      end
    end

    # Raised when a stage reference cannot be resolved.
    #
    # @example
    #   pipeline do
    #     processor :a, routes_to: :nonexistent do |item, output|  # Raises UnresolvedReference
    #       output << item
    #     end
    #   end
    class UnresolvedReference < PipelineError
      # @return [Symbol, String, nil] The unresolved reference
      attr_reader :reference

      # @return [Array<Symbol, String>] List of available stage names
      attr_reader :available_stages

      # @param message [String, nil] Custom error message
      # @param pipeline_name [String, nil] The pipeline name
      # @param reference [Symbol, String, nil] The unresolved reference
      # @param available_stages [Array] List of available stages
      def initialize(message = nil, pipeline_name: nil, reference: nil, available_stages: [])
        @reference = reference
        @available_stages = available_stages
        msg = message || "Cannot find stage '#{reference}' in pipeline '#{pipeline_name}'"
        super(msg, pipeline_name: pipeline_name, reference: reference)
      end
    end

    # Raised when an item cannot be serialized for IPC communication.
    #
    # @example
    #   in_ipc_forks(4) do
    #     processor :work do |item, output|
    #       output << lambda { }  # Raises SerializationFailed - lambdas can't be marshaled
    #     end
    #   end
    class SerializationFailed < PipelineError
      # @return [String, nil] The class name of the item that couldn't be serialized
      attr_reader :item_class

      # @return [Exception, nil] The original serialization error
      attr_reader :original_error

      # @param message [String, nil] Custom error message
      # @param item_class [String, nil] The item's class name
      # @param original_error [Exception, nil] The underlying error
      def initialize(message = nil, item_class: nil, original_error: nil)
        @item_class = item_class
        @original_error = original_error
        msg = message || "Cannot serialize item of type #{item_class}: #{original_error&.message}"
        super(msg, item_class: item_class)
      end
    end

    # ============================================
    # Execution Errors (runtime)
    # ============================================

    # Base class for runtime execution errors.
    # These errors occur during pipeline execution.
    class ExecutionError < BaseError; end

    # Base class for errors occurring within a specific stage.
    class StageError < ExecutionError
      # @return [Symbol, String, nil] The stage name where the error occurred
      attr_reader :stage_name

      # @param message [String, nil] Custom error message
      # @param stage_name [Symbol, String, nil] The stage name
      # @param context [Hash] Additional context
      def initialize(message = nil, stage_name: nil, **context)
        @stage_name = stage_name
        super(message, stage_name: stage_name, **context)
      end
    end

    # Raised when an item fails processing within a stage.
    # Wraps the original error with stage and item context.
    class ItemProcessingFailed < StageError
      # @return [Object, nil] The item that failed to process
      attr_reader :item

      # @return [Exception, nil] The original error that caused the failure
      attr_reader :original_error

      # @param message [String, nil] Custom error message
      # @param stage_name [Symbol, String, nil] The stage name
      # @param item [Object, nil] The item that failed
      # @param original_error [Exception, nil] The underlying error
      def initialize(message = nil, stage_name: nil, item: nil, original_error: nil)
        @item = item
        @original_error = original_error
        msg = message || "Error processing item in stage '#{stage_name}': #{original_error&.message}"
        super(msg, stage_name: stage_name, item_class: item&.class&.name)
        set_backtrace(original_error.backtrace) if original_error&.backtrace
      end
    end

    # Raised when retry attempts are exhausted for an operation.
    class RetryExhausted < StageError
      # @return [Integer, nil] Number of attempts made
      attr_reader :attempts

      # @return [Exception, nil] The last error before giving up
      attr_reader :original_error

      # @param message [String, nil] Custom error message
      # @param stage_name [Symbol, String, nil] The stage name
      # @param attempts [Integer, nil] Number of attempts
      # @param original_error [Exception, nil] The last error
      def initialize(message = nil, stage_name: nil, attempts: nil, original_error: nil)
        @attempts = attempts
        @original_error = original_error
        msg = message || "Retry exhausted after #{attempts} attempts: #{original_error&.message}"
        super(msg, stage_name: stage_name, attempts: attempts)
        set_backtrace(original_error.backtrace) if original_error&.backtrace
      end
    end

    # Raised when a hook fails execution.
    class HookFailed < ExecutionError
      # @return [Symbol, nil] The hook type (:before, :after, :before_fork, etc.)
      attr_reader :hook_type

      # @return [Symbol, String, nil] The stage name if this is a stage hook
      attr_reader :stage_name

      # @return [Exception, nil] The original error from the hook
      attr_reader :original_error

      # @param message [String, nil] Custom error message
      # @param hook_type [Symbol, nil] The hook type
      # @param stage_name [Symbol, String, nil] The stage name
      # @param original_error [Exception, nil] The underlying error
      def initialize(message = nil, hook_type: nil, stage_name: nil, original_error: nil)
        @hook_type = hook_type
        @stage_name = stage_name
        @original_error = original_error
        stage_part = stage_name ? " for '#{stage_name}'" : ''
        msg = message || "Hook #{hook_type}#{stage_part} failed: #{original_error&.message}"
        super(msg, hook_type: hook_type, stage_name: stage_name)
        set_backtrace(original_error.backtrace) if original_error&.backtrace
      end
    end

    # Raised when a circuit breaker is open and rejecting calls.
    class CircuitBreakerOpen < ExecutionError
      # @return [Symbol, String, nil] The circuit breaker name/identifier
      attr_reader :circuit_name

      # @return [Float, nil] Seconds until the circuit may close
      attr_reader :retry_after

      # @param message [String, nil] Custom error message
      # @param circuit_name [Symbol, String, nil] The circuit name
      # @param retry_after [Float, nil] Seconds until retry
      def initialize(message = nil, circuit_name: nil, retry_after: nil)
        @circuit_name = circuit_name
        @retry_after = retry_after
        msg = message || "Circuit breaker '#{circuit_name}' is open. Retry after #{retry_after&.round(1)}s"
        super(msg, circuit_name: circuit_name, retry_after: retry_after)
      end
    end

    # ============================================
    # Cluster Errors (distributed execution)
    # ============================================

    # Base class for cluster-related errors.
    # All cluster-specific errors inherit from this class.
    #
    # @example Catching all cluster errors
    #   begin
    #     pipeline.run
    #   rescue Minigun::Errors::ClusterError => e
    #     logger.error "Cluster error: #{e.message}"
    #   end
    class ClusterError < BaseError; end

    # Raised when connection to a coordinator or worker fails.
    #
    # @example
    #   in_cluster(coordinator_uri: 'druby://invalid:9000') do
    #     processor :work do |item, output|
    #       output << item
    #     end
    #   end
    class ClusterConnectionFailed < ClusterError
      # @return [String, nil] The URI that failed to connect
      attr_reader :uri

      # @return [Exception, nil] The original connection error
      attr_reader :original_error

      # @param message [String, nil] Custom error message
      # @param uri [String, nil] The failed URI
      # @param original_error [Exception, nil] The underlying error
      def initialize(message = nil, uri: nil, original_error: nil)
        @uri = uri
        @original_error = original_error
        msg = message || "Failed to connect to #{uri}: #{original_error&.message}"
        super(msg, uri: uri)
      end
    end

    # Raised when a required stage processor is not found on any worker.
    #
    # @example
    #   # Worker doesn't have :process stage registered
    #   in_cluster(worker_uris: ['druby://worker:9001']) do
    #     processor :process do |item, output|  # Raises ClusterWorkerNotFound
    #       output << item
    #     end
    #   end
    class ClusterWorkerNotFound < ClusterError
      # @return [Symbol, String, nil] The stage name that couldn't be found
      attr_reader :stage_name

      # @return [Array<Symbol, String>] List of stages available on workers
      attr_reader :available_stages

      # @param message [String, nil] Custom error message
      # @param stage_name [Symbol, String, nil] The missing stage name
      # @param available_stages [Array] Available stages on workers
      def initialize(message = nil, stage_name: nil, available_stages: [])
        @stage_name = stage_name
        @available_stages = available_stages
        msg = message || "No worker has processor for stage '#{stage_name}'"
        super(msg, stage_name: stage_name, available_stages: available_stages)
      end
    end

    # Raised when item delivery fails after all retry attempts.
    #
    # @example
    #   in_cluster(worker_uris: [...], delivery_mode: :at_least_once, max_retries: 3) do
    #     processor :flaky do |item, output|
    #       # After 3 failed attempts, raises ClusterDeliveryFailed
    #       output << unreliable_operation(item)
    #     end
    #   end
    class ClusterDeliveryFailed < ClusterError
      # @return [Object, nil] The item ID that failed delivery
      attr_reader :item_id

      # @return [Integer, nil] Number of delivery attempts made
      attr_reader :attempts

      # @return [Exception, nil] The last error encountered
      attr_reader :last_error

      # @param message [String, nil] Custom error message
      # @param item_id [Object, nil] The item identifier
      # @param attempts [Integer, nil] Number of attempts
      # @param last_error [Exception, nil] The last error
      def initialize(message = nil, item_id: nil, attempts: nil, last_error: nil)
        @item_id = item_id
        @attempts = attempts
        @last_error = last_error
        msg = message || "Failed to deliver item #{item_id} after #{attempts} attempts"
        super(msg, item_id: item_id, attempts: attempts)
      end
    end

    # Raised when a cluster operation times out.
    #
    # @example
    #   in_cluster(coordinator_uri: '...', min_workers: 4, worker_wait_timeout: 10) do
    #     # Raises ClusterTimedOut if 4 workers don't connect within 10 seconds
    #     processor :work do |item, output|
    #       output << item
    #     end
    #   end
    class ClusterTimedOut < ClusterError
      # @return [String, nil] Description of the operation that timed out
      attr_reader :operation

      # @return [Float, Integer, nil] The timeout duration in seconds
      attr_reader :timeout_seconds

      # @param message [String, nil] Custom error message
      # @param operation [String, nil] The operation description
      # @param timeout_seconds [Float, Integer, nil] The timeout value
      def initialize(message = nil, operation: nil, timeout_seconds: nil)
        @operation = operation
        @timeout_seconds = timeout_seconds
        msg = message || "Cluster operation '#{operation}' timed out after #{timeout_seconds}s"
        super(msg, operation: operation, timeout_seconds: timeout_seconds)
      end
    end
  end
end
