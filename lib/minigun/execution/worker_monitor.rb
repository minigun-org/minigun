# frozen_string_literal: true

module Minigun
  module Execution
    # Monitors worker processes and manages restart policies
    #
    # Responsible for:
    # - Validating restart policies
    # - Deciding whether workers should be restarted based on exit status
    # - Rate limiting restarts per worker
    # - Formatting exit status for logging
    #
    # This class is stateful but thread-safe. It tracks restart history
    # per worker index to enforce rate limits.
    class WorkerMonitor
      RESTART_POLICIES = %i[never transient permanent].freeze

      attr_reader :restart_policy, :max_restarts, :restart_window

      # @param restart_policy [Symbol] One of :never, :transient, :permanent
      # @param max_restarts [Integer] Maximum restarts per worker in the window
      # @param restart_window [Integer] Time window in seconds for counting restarts
      def initialize(restart_policy: :never, max_restarts: 3, restart_window: 60)
        @restart_policy = validate_policy(restart_policy)
        @max_restarts = max_restarts
        @restart_window = restart_window
        @worker_restarts = {} # worker_index => [restart_timestamps]
        @mutex = Mutex.new
        @shutdown_requested = false
      end

      # Whether monitoring/restart is enabled
      def enabled?
        @restart_policy != :never
      end

      # Request shutdown - stops the monitoring loop
      def request_shutdown
        @mutex.synchronize { @shutdown_requested = true }
      end

      # Check if shutdown was requested
      def shutdown_requested?
        @mutex.synchronize { @shutdown_requested }
      end

      # Check if a worker should be restarted based on exit status and policy
      # @param process_status [Process::Status] Exit status from Process.wait2
      # @return [Boolean] Whether the worker should be restarted
      def should_restart?(process_status)
        return false if @restart_policy == :never
        return true if @restart_policy == :permanent

        # :transient - restart only on abnormal exit
        return true if process_status.signaled? # Killed by signal
        return true if process_status.exitstatus && process_status.exitstatus != 0 # Non-zero exit

        false
      end

      # Check if we've exceeded the restart limit for a worker
      # @param worker_index [Integer] Index of the worker
      # @return [Boolean] Whether restart is allowed
      def restart_allowed?(worker_index)
        @mutex.synchronize do
          now = Time.now
          @worker_restarts[worker_index] ||= []

          # Remove restarts outside the window
          @worker_restarts[worker_index].reject! { |t| now - t > @restart_window }

          # Check if we're under the limit
          @worker_restarts[worker_index].size < @max_restarts
        end
      end

      # Record a restart for rate limiting
      # @param worker_index [Integer] Index of the worker being restarted
      def record_restart(worker_index)
        @mutex.synchronize do
          @worker_restarts[worker_index] ||= []
          @worker_restarts[worker_index] << Time.now
        end
      end

      # Get the number of restarts for a worker in the current window
      # @param worker_index [Integer] Index of the worker
      # @return [Integer] Number of restarts in the window
      def restart_count(worker_index)
        @mutex.synchronize do
          now = Time.now
          restarts = @worker_restarts[worker_index] || []
          restarts.count { |t| now - t <= @restart_window }
        end
      end

      # Format exit status for logging
      # @param status [Process::Status] Exit status from Process.wait2
      # @return [String] Human-readable exit status
      def format_exit_status(status)
        if status.signaled?
          "signal #{status.termsig}"
        elsif status.exitstatus
          "exit code #{status.exitstatus}"
        else
          'unknown'
        end
      end

      private

      def validate_policy(policy)
        policy = policy.to_sym
        unless RESTART_POLICIES.include?(policy)
          raise ArgumentError.new("Invalid restart_policy: #{policy}. Valid: #{RESTART_POLICIES.join(', ')}")
        end

        policy
      end
    end
  end
end
