# frozen_string_literal: true

require 'drb'
require 'socket'
require 'timeout'
require_relative 'cluster/barrier'
require_relative 'cluster/delivery_tracker'
require_relative 'cluster/distributor'

module Minigun
  # Distributed clustering support using DRb
  # Enables pipeline stages to be executed across multiple machines
  module Cluster
    # Coordinator manages work distribution across cluster nodes
    # Runs on the "head" node and accepts connections from workers
    class Coordinator
      attr_reader :uri, :workers, :stage_name

      def initialize(bind_address: nil, port: 9000, stage_name: nil)
        @bind_address = bind_address || '0.0.0.0'
        @port = port
        @stage_name = stage_name
        @workers = {}
        @work_queue = Queue.new
        @result_queue = Queue.new
        @mutex = Mutex.new
        @running = false
      end

      # Start the DRb service
      def start
        @uri = "druby://#{@bind_address}:#{@port}"
        @drb_server = DRb.start_service(@uri, self)
        @running = true
        Minigun.logger.info "[Cluster] Coordinator started at #{@uri}"
        @uri
      end

      # Stop the coordinator
      def stop
        @running = false
        # Signal all workers to shutdown (with timeout to avoid hanging)
        @workers.each_value do |worker|
          Timeout.timeout(1) { worker[:proxy].shutdown }
        rescue StandardError
          # Worker may be gone or unresponsive
        end
        @workers.clear
        begin
          @drb_server&.stop_service
        rescue StandardError
          nil
        end
        @drb_server = nil
        Minigun.logger.info '[Cluster] Coordinator stopped'
      end

      # Worker registration (called remotely by workers)
      def register_worker(worker_uri, worker_id, capabilities = {})
        @mutex.synchronize do
          @workers[worker_id] = {
            uri: worker_uri,
            proxy: DRbObject.new_with_uri(worker_uri),
            capabilities: capabilities,
            registered_at: Time.now,
            last_heartbeat: Time.now
          }
        end
        Minigun.logger.info "[Cluster] Worker registered: #{worker_id} at #{worker_uri}"
        true
      end

      # Worker heartbeat (called remotely by workers)
      def heartbeat(worker_id)
        @mutex.synchronize do
          if @workers[worker_id]
            @workers[worker_id][:last_heartbeat] = Time.now
            true
          else
            false # Worker not registered
          end
        end
      end

      # Worker unregistration (called remotely by workers)
      def unregister_worker(worker_id)
        @mutex.synchronize do
          @workers.delete(worker_id)
        end
        Minigun.logger.info "[Cluster] Worker unregistered: #{worker_id}"
        true
      end

      # Request work item (pull-based, called remotely by workers)
      def request_work
        return nil unless @running

        begin
          @work_queue.pop(true) # Non-blocking
        rescue ThreadError
          nil # Queue empty
        end
      end

      # Submit result (called remotely by workers)
      def submit_result(result)
        @result_queue.push(result)
        true
      end

      # Submit error (called remotely by workers)
      def submit_error(error_info)
        Minigun.logger.error "[Cluster] Worker error: #{error_info[:message]}"
        Minigun.logger.debug error_info[:backtrace]&.join("\n") if Minigun.logger.debug?
        # Still count as item done
        @result_queue.push({ type: :error, error: error_info })
        true
      end

      # Internal: Queue work item for distribution
      def enqueue_work(item)
        @work_queue.push({ type: :item, item: item })
      end

      # Internal: Signal end of work
      def enqueue_end_of_stage
        # Send shutdown signal to each worker
        worker_count = @mutex.synchronize { @workers.size }
        worker_count.times { @work_queue.push({ type: :shutdown }) }
      end

      # Internal: Collect next result
      # With timeout: does non-blocking check with optional sleep to yield to other threads
      # Without timeout: blocking pop
      def collect_result(timeout: nil)
        if timeout&.>(0)
          begin
            @result_queue.pop(true)
          rescue ThreadError
            # Queue empty - sleep briefly to yield CPU to other threads
            # This prevents busy-spinning that can starve other threads in same process
            sleep(timeout)
            nil
          end
        else
          @result_queue.pop
        end
      end

      # Internal: Check if results pending
      def results_pending?
        !@result_queue.empty?
      end

      # Internal: Get worker count
      def worker_count
        @mutex.synchronize { @workers.size }
      end

      # Internal: Wait for minimum workers
      def wait_for_workers(min_count:, timeout: 30)
        deadline = Time.now + timeout
        loop do
          return true if worker_count >= min_count
          return false if Time.now > deadline

          sleep 0.1
        end
      end
    end

    # Worker node that connects to a coordinator and processes work
    class Worker
      attr_reader :worker_id, :coordinator_uri

      def initialize(coordinator_uri:, worker_id: nil, stage_registry: nil)
        @coordinator_uri = coordinator_uri
        @worker_id = worker_id || generate_worker_id
        @stage_registry = stage_registry || {}
        @running = false
        @coordinator = nil
        @heartbeat_thread = nil
        @heartbeat_interval = 5 # seconds
      end

      # Connect to coordinator and register
      def connect
        DRb.start_service
        @coordinator = DRbObject.new_with_uri(@coordinator_uri)

        # Get our DRb URI for the coordinator to call back
        # Start a local service to receive calls
        @local_service = WorkerService.new(self)
        DRb.start_service(nil, @local_service)
        local_uri = DRb.uri

        @coordinator.register_worker(local_uri, @worker_id, capabilities)
        Minigun.logger.info "[Cluster] Worker #{@worker_id} connected to #{@coordinator_uri}"
        true
      rescue DRb::DRbConnError => e
        raise Errors::ClusterConnectionFailed.new(
          uri: @coordinator_uri,
          original_error: e
        )
      end

      # Start processing work
      def start
        @running = true
        start_heartbeat

        Minigun.logger.info "[Cluster] Worker #{@worker_id} starting work loop"
        work_loop
      ensure
        stop_heartbeat
        disconnect
      end

      # Stop the worker
      def stop
        @running = false
      end

      # Register a stage processor
      def register_stage(name, &block)
        @stage_registry[name.to_sym] = block
      end

      # Shutdown (called by coordinator)
      def shutdown
        @running = false
      end

      # Direct mode: Process a single item synchronously and return results
      # Used when connecting directly to workers without a coordinator
      # Returns array of results (may be empty, single, or multiple)
      def process_item_sync(stage_name, item)
        stage_proc = @stage_registry[stage_name.to_sym] || @stage_registry[:default]

        unless stage_proc
          raise Errors::ClusterWorkerNotFound.new(
            stage_name: stage_name,
            available_stages: @stage_registry.keys
          )
        end

        results = []
        output_collector = ->(result) { results << result }

        stage_proc.call(item, output_collector)

        # Return all results (supports fan-out stages)
        results
      end

      private

      def generate_worker_id
        hostname = Socket.gethostname
        pid = Process.pid
        "#{hostname}-#{pid}-#{SecureRandom.hex(4)}"
      end

      def capabilities
        {
          hostname: Socket.gethostname,
          pid: Process.pid,
          ruby_version: RUBY_VERSION,
          platform: RUBY_PLATFORM,
          stages: @stage_registry.keys
        }
      end

      def start_heartbeat
        @heartbeat_thread = Thread.new do
          loop do
            break unless @running

            sleep @heartbeat_interval
            begin
              @coordinator.heartbeat(@worker_id)
            rescue DRb::DRbConnError
              Minigun.logger.warn '[Cluster] Lost connection to coordinator'
              @running = false
              break
            end
          end
        end
      end

      def stop_heartbeat
        @heartbeat_thread&.kill
        @heartbeat_thread = nil
      end

      def disconnect
        @coordinator&.unregister_worker(@worker_id)
      rescue StandardError
        # Coordinator may already be gone
      ensure
        DRb.stop_service
      end

      def work_loop
        while @running
          work = request_work
          next sleep(0.01) if work.nil? # No work available, wait briefly

          break if work[:type] == :shutdown

          process_work(work)
        end
      end

      def request_work
        @coordinator.request_work
      rescue DRb::DRbConnError
        Minigun.logger.warn '[Cluster] Lost connection to coordinator'
        @running = false
        nil
      end

      def process_work(work)
        # work is { type: :item, item: { stage: ..., item: ... } }
        work_data = work[:item]
        item = work_data[:item]
        stage_name = work_data[:stage]&.to_sym
        stage_proc = @stage_registry[stage_name] || @stage_registry[:default]

        unless stage_proc
          Minigun.logger.warn "[Cluster] No processor for stage :#{stage_name}"
          return
        end

        start_time = Time.now
        results = []
        output_collector = ->(result) { results << result }

        begin
          # Call with (item, output) signature like local stages
          stage_proc.call(item, output_collector)

          # Submit results
          results.each do |result|
            @coordinator.submit_result(
              {
                type: :result,
                result: result,
                worker_id: @worker_id,
                latency: Time.now - start_time
              }
            )
          end

          # If no results, still signal completion
          if results.empty?
            @coordinator.submit_result(
              {
                type: :item_done,
                worker_id: @worker_id,
                latency: Time.now - start_time
              }
            )
          end
        rescue DRb::DRbConnError => e
          # Coordinator disconnected during processing - log and continue
          Minigun.logger.warn "[Cluster] Lost connection to coordinator during processing: #{e.message}"
          @running = false
        rescue StandardError => e
          @coordinator.submit_error(
            {
              message: e.message,
              backtrace: e.backtrace,
              worker_id: @worker_id,
              item: item.inspect[0..200] # Truncated for safety
            }
          )
        end
      end
    end

    # Service object exposed by worker for coordinator callbacks and direct mode
    class WorkerService
      def initialize(worker)
        @worker = worker
      end

      def shutdown
        @worker.shutdown
      end

      def ping
        :pong
      end

      # Direct mode: Process a single item synchronously and return result
      # Used when connecting directly to workers without a coordinator
      def process_item(stage_name, item)
        @worker.process_item_sync(stage_name, item)
      end
    end

    # Discovery strategies for finding cluster nodes
    module Discovery
      # Manual/static list of workers
      class Static
        def initialize(workers:)
          @workers = workers
        end

        def discover
          @workers
        end
      end

      # Gossip-based discovery using rswim gem (optional)
      class Gossip
        def initialize(port:, seed_hosts: [], encryption_key: nil)
          @port = port
          @seed_hosts = seed_hosts
          @encryption_key = encryption_key
          @discovered_workers = []

          begin
            require 'rswim'
            @available = true
          rescue LoadError
            @available = false
          end
        end

        def available?
          @available
        end

        def start
          unless @available
            raise Errors::ConfigurationError.new("Gossip discovery requires the 'rswim' gem. Add `gem 'rswim'` to your Gemfile.")
          end

          if @encryption_key
            RSwim.encrypted = true
            RSwim.shared_secret = @encryption_key
          end

          @node = RSwim::Node.udp(nil, @seed_hosts, @port)

          @node.subscribe do |host, status, custom_state|
            case status
            when :alive
              if custom_state&.dig(:type) == :minigun_worker
                @discovered_workers << {
                  host: host,
                  uri: custom_state[:drb_uri],
                  stage: custom_state[:stage]
                }
              end
            when :dead, :suspect
              @discovered_workers.reject! { |w| w[:host] == host }
            end
          end

          Thread.new { @node.start }
        end

        def stop
          @node&.stop
        end

        def discover
          @discovered_workers.dup
        end

        def announce(drb_uri:, stage:)
          @node&.append_custom_state(:type, :minigun_worker)
          @node&.append_custom_state(:drb_uri, drb_uri)
          @node&.append_custom_state(:stage, stage)
        end
      end
    end
  end
end
