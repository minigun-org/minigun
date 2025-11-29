# frozen_string_literal: true

require 'spec_helper'
require 'drb'
require 'timeout'
require 'socket'

# Jepsen-style tests for Cluster execution
# These tests focus on:
# - Network partition handling
# - Delivery guarantees (at-least-once vs at-most-once)
# - Worker failure and recovery
# - Dynamic cluster membership
# - Data integrity under failure conditions
# - Split-brain scenarios

RSpec.describe 'Cluster Executor - Jepsen-style Tests' do
  # Test harness for simulating network conditions
  class NetworkSimulator
    attr_reader :partitioned_workers, :delayed_workers, :failed_workers

    def initialize
      @partitioned_workers = Set.new
      @delayed_workers = {} # worker_id => delay_ms
      @failed_workers = Set.new
      @mutex = Mutex.new
    end

    def partition(worker_id)
      @mutex.synchronize { @partitioned_workers.add(worker_id) }
    end

    def heal_partition(worker_id)
      @mutex.synchronize { @partitioned_workers.delete(worker_id) }
    end

    def add_delay(worker_id, delay_ms)
      @mutex.synchronize { @delayed_workers[worker_id] = delay_ms }
    end

    def remove_delay(worker_id)
      @mutex.synchronize { @delayed_workers.delete(worker_id) }
    end

    def fail_worker(worker_id)
      @mutex.synchronize { @failed_workers.add(worker_id) }
    end

    def recover_worker(worker_id)
      @mutex.synchronize { @failed_workers.delete(worker_id) }
    end

    def can_communicate?(worker_id)
      @mutex.synchronize do
        !@partitioned_workers.include?(worker_id) && !@failed_workers.include?(worker_id)
      end
    end

    def get_delay(worker_id)
      @mutex.synchronize { @delayed_workers[worker_id] || 0 }
    end

    def reset!
      @mutex.synchronize do
        @partitioned_workers.clear
        @delayed_workers.clear
        @failed_workers.clear
      end
    end
  end

  # Test service that wraps a real worker and applies network simulation
  class SimulatedWorkerService
    attr_accessor :network_sim, :worker, :worker_id, :flag, :process_count

    def initialize(worker, worker_id, network_sim, flag)
      @worker = worker
      @worker_id = worker_id
      @network_sim = network_sim
      @flag = flag
      @process_count = 0
      @mutex = Mutex.new
    end

    def ping
      raise DRb::DRbConnError, 'Network partition' unless @network_sim.can_communicate?(@worker_id)

      delay = @network_sim.get_delay(@worker_id)
      sleep(delay / 1000.0) if delay.positive?
      :pong
    end

    def process_item(stage_name, item)
      raise DRb::DRbConnError, 'Network partition' unless @network_sim.can_communicate?(@worker_id)

      delay = @network_sim.get_delay(@worker_id)
      sleep(delay / 1000.0) if delay.positive?

      @mutex.synchronize { @process_count += 1 }
      @worker.process_item_sync(stage_name, item)
    end

    def shutdown
      @flag[:shutdown] = true
    end

    def get_process_count
      @mutex.synchronize { @process_count }
    end
  end

  # Delivery tracking for exactly-once/at-least-once verification
  class DeliveryTracker
    attr_reader :items_sent, :items_received, :items_processed

    def initialize
      @items_sent = []
      @items_received = []
      @items_processed = []
      @mutex = Mutex.new
    end

    def track_sent(item_id)
      @mutex.synchronize { @items_sent << item_id }
    end

    def track_received(item_id)
      @mutex.synchronize { @items_received << item_id }
    end

    def track_processed(item_id)
      @mutex.synchronize { @items_processed << item_id }
    end

    def duplicates
      @mutex.synchronize { @items_received.tally.select { |_k, v| v > 1 } }
    end

    def missing
      @mutex.synchronize { @items_sent - @items_received }
    end

    def extra
      @mutex.synchronize { @items_received - @items_sent }
    end

    def reset!
      @mutex.synchronize do
        @items_sent.clear
        @items_received.clear
        @items_processed.clear
      end
    end

    def stats
      @mutex.synchronize do
        {
          sent: @items_sent.size,
          received: @items_received.size,
          processed: @items_processed.size,
          duplicates: @items_received.tally.select { |_k, v| v > 1 }.size,
          missing: (@items_sent - @items_received).size
        }
      end
    end
  end

  let(:network_sim) { NetworkSimulator.new }
  let(:delivery_tracker) { DeliveryTracker.new }

  # Track started services for cleanup
  let(:started_services) { [] }

  # Find available ports for testing
  def find_available_port
    server = TCPServer.new('127.0.0.1', 0)
    port = server.addr[1]
    server.close
    port
  end

  # Create a tracked worker that reports to delivery tracker
  def create_tracked_worker(port, network_sim, delivery_tracker)
    worker = Minigun::Cluster::Worker.new(coordinator_uri: nil, worker_id: "tracked-worker-#{port}")
    flag = { port: port, shutdown: false, items: 0 }

    worker.register_stage(:tracked_process) do |item, output|
      flag[:items] += 1
      delivery_tracker.track_processed(item[:id])
      # Simulate processing
      result = { id: item[:id], processed: true, value: item[:value] * 2, worker_port: port }
      output.call(result)
    end

    service = SimulatedWorkerService.new(worker, "tracked-worker-#{port}", network_sim, flag)
    uri = "druby://127.0.0.1:#{port}"

    [worker, service, uri, flag]
  end

  # Helper to start DRb services for multiple workers
  def start_workers(count, network_sim, delivery_tracker, services_list)
    workers = []
    count.times do
      port = find_available_port
      worker, service, uri, flag = create_tracked_worker(port, network_sim, delivery_tracker)
      drb_server = DRb.start_service(uri, service)
      services_list << drb_server
      workers << { worker: worker, service: service, uri: uri, flag: flag, port: port }
    end
    workers
  end

  # Stop all DRb services
  def cleanup_services(services_list)
    services_list.each do |service|
      service.stop_service rescue nil
    end
    services_list.clear
    # Give OS time to release ports
    sleep 0.05
  end

  after(:each) do
    network_sim.reset!
    cleanup_services(started_services)
    DRb.stop_service rescue nil
  end

  describe 'Data Integrity' do
    it 'processes all items exactly once under normal conditions' do
      workers = start_workers(3, network_sim, delivery_tracker, started_services)
      items = (1..50).map { |i| { id: i, value: i } }
      results = []
      results_mutex = Mutex.new

      klass = Class.new do
        include Minigun::DSL

        def initialize(worker_uris, items, results, results_mutex, tracker)
          @worker_uris = worker_uris
          @items = items
          @results = results
          @results_mutex = results_mutex
          @tracker = tracker
        end

        pipeline do
          producer :generate do |output|
            @items.each do |item|
              @tracker.track_sent(item[:id])
              output << item
            end
          end

          in_cluster(worker_uris: @worker_uris, shutdown_on_done: false) do
            processor :tracked_process do |item, output|
              output << item
            end
          end

          consumer :collect do |item|
            @tracker.track_received(item[:id])
            @results_mutex.synchronize { @results << item }
          end
        end
      end

      pipeline = klass.new(workers.map { |w| w[:uri] }, items, results, results_mutex, delivery_tracker)
      pipeline.run

      # Verify exactly-once delivery
      expect(delivery_tracker.duplicates).to be_empty, "Duplicates found: #{delivery_tracker.duplicates}"
      expect(delivery_tracker.missing).to be_empty, "Missing items: #{delivery_tracker.missing}"
      expect(results.size).to eq(items.size)

      # Verify correct processing
      result_ids = results.map { |r| r[:id] }.sort
      expect(result_ids).to eq((1..50).to_a)
    end

    it 'handles duplicate input values correctly' do
      workers = start_workers(2, network_sim, delivery_tracker, started_services)
      # Items with duplicate IDs (different values)
      items = [
        { id: 1, value: 10 },
        { id: 2, value: 20 },
        { id: 1, value: 15 }, # Duplicate ID
        { id: 3, value: 30 },
        { id: 2, value: 25 }  # Duplicate ID
      ]

      results = []
      results_mutex = Mutex.new

      klass = Class.new do
        include Minigun::DSL

        def initialize(worker_uris, items, results, results_mutex)
          @worker_uris = worker_uris
          @items = items
          @results = results
          @results_mutex = results_mutex
        end

        pipeline do
          producer :generate do |output|
            @items.each { |item| output << item }
          end

          in_cluster(worker_uris: @worker_uris, shutdown_on_done: false) do
            processor :tracked_process do |item, output|
              output << item
            end
          end

          consumer :collect do |item|
            @results_mutex.synchronize { @results << item }
          end
        end
      end

      pipeline = klass.new(workers.map { |w| w[:uri] }, items, results, results_mutex)
      pipeline.run

      # All items should be processed (including duplicates)
      expect(results.size).to eq(5)
    end

    it 'distributes work across all workers' do
      workers = start_workers(3, network_sim, delivery_tracker, started_services)
      items = (1..30).map { |i| { id: i, value: i } }
      results = []
      results_mutex = Mutex.new

      klass = Class.new do
        include Minigun::DSL

        def initialize(worker_uris, items, results, results_mutex)
          @worker_uris = worker_uris
          @items = items
          @results = results
          @results_mutex = results_mutex
        end

        pipeline do
          producer :generate do |output|
            @items.each { |item| output << item }
          end

          in_cluster(worker_uris: @worker_uris, shutdown_on_done: false) do
            processor :tracked_process do |item, output|
              output << item
            end
          end

          consumer :collect do |item|
            @results_mutex.synchronize { @results << item }
          end
        end
      end

      pipeline = klass.new(workers.map { |w| w[:uri] }, items, results, results_mutex)
      pipeline.run

      # Verify work was distributed
      worker_counts = workers.map { |w| w[:service].get_process_count }
      expect(worker_counts.sum).to eq(30)

      # Each worker should have processed some items (round-robin)
      worker_counts.each do |count|
        expect(count).to be > 0, 'Worker processed no items'
      end
    end
  end

  describe 'Network Partition Handling' do
    it 'handles temporary network partition during processing' do
      workers = start_workers(3, network_sim, delivery_tracker, started_services)
      items = (1..20).map { |i| { id: i, value: i } }
      results = []
      results_mutex = Mutex.new

      klass = Class.new do
        include Minigun::DSL

        def initialize(worker_uris, items, results, results_mutex, network_sim, workers)
          @worker_uris = worker_uris
          @items = items
          @results = results
          @results_mutex = results_mutex
          @network_sim = network_sim
          @workers = workers
          @partition_applied = false
        end

        pipeline do
          producer :generate do |output|
            @items.each_with_index do |item, idx|
              # Partition first worker midway through
              if idx == 10 && !@partition_applied
                @network_sim.partition(@workers.first[:service].worker_id)
                @partition_applied = true
              end
              output << item
            end
          end

          in_cluster(worker_uris: @worker_uris, shutdown_on_done: false) do
            processor :tracked_process do |item, output|
              output << item
            end
          end

          consumer :collect do |item|
            @results_mutex.synchronize { @results << item }
          end
        end
      end

      # Note: Current implementation doesn't retry on failure, so partitioned worker's
      # items may be lost. This test documents current behavior.
      begin
        pipeline = klass.new(workers.map { |w| w[:uri] }, items, results, results_mutex, network_sim, workers)
        Timeout.timeout(10) { pipeline.run }
      rescue Minigun::Cluster::Error, DRb::DRbConnError
        # Expected when partition causes connection errors
      end

      # Some results should have been collected before/after partition
      # Current behavior: items to partitioned worker are lost
      expect(results.size).to be_between(1, items.size)
    end

    it 'handles worker becoming unresponsive (high latency)' do
      workers = start_workers(2, network_sim, delivery_tracker, started_services)
      items = (1..10).map { |i| { id: i, value: i } }
      results = []
      results_mutex = Mutex.new

      # Add high latency to first worker
      network_sim.add_delay(workers.first[:service].worker_id, 200) # 200ms delay

      klass = Class.new do
        include Minigun::DSL

        def initialize(worker_uris, items, results, results_mutex)
          @worker_uris = worker_uris
          @items = items
          @results = results
          @results_mutex = results_mutex
        end

        pipeline do
          producer :generate do |output|
            @items.each { |item| output << item }
          end

          in_cluster(worker_uris: @worker_uris, shutdown_on_done: false) do
            processor :tracked_process do |item, output|
              output << item
            end
          end

          consumer :collect do |item|
            @results_mutex.synchronize { @results << item }
          end
        end
      end

      pipeline = klass.new(workers.map { |w| w[:uri] }, items, results, results_mutex)

      start_time = Time.now
      pipeline.run
      elapsed = Time.now - start_time

      # Should complete despite delays (but slower)
      expect(results.size).to eq(10)
      expect(elapsed).to be > 0.3 # At least some delay effect (200ms * 5 items / parallel)
    end
  end

  describe 'Worker Failure and Recovery' do
    it 'handles worker failure after processing some items' do
      workers = start_workers(3, network_sim, delivery_tracker, started_services)
      items = (1..30).map { |i| { id: i, value: i } }
      results = []
      results_mutex = Mutex.new

      # Track when to fail the worker
      fail_counter = 0
      fail_mutex = Mutex.new

      # Wrap first worker's service to fail after 5 items
      original_process = workers.first[:service].method(:process_item)
      workers.first[:service].define_singleton_method(:process_item) do |stage_name, item|
        fail_mutex.synchronize { fail_counter += 1 }
        raise DRb::DRbConnError, 'Worker crashed' if fail_counter > 5

        original_process.call(stage_name, item)
      end

      klass = Class.new do
        include Minigun::DSL

        def initialize(worker_uris, items, results, results_mutex)
          @worker_uris = worker_uris
          @items = items
          @results = results
          @results_mutex = results_mutex
        end

        pipeline do
          producer :generate do |output|
            @items.each { |item| output << item }
          end

          in_cluster(worker_uris: @worker_uris, shutdown_on_done: false) do
            processor :tracked_process do |item, output|
              output << item
            end
          end

          consumer :collect do |item|
            @results_mutex.synchronize { @results << item }
          end
        end
      end

      begin
        pipeline = klass.new(workers.map { |w| w[:uri] }, items, results, results_mutex)
        Timeout.timeout(15) { pipeline.run }
      rescue Minigun::Cluster::Error
        # Expected - worker failure
      end

      # Should have partial results from surviving workers
      # Current behavior: some items lost when worker fails
      expect(results.size).to be > 0
    end

    it 'completes when all workers are available throughout' do
      workers = start_workers(2, network_sim, delivery_tracker, started_services)
      items = (1..20).map { |i| { id: i, value: i } }
      results = []
      results_mutex = Mutex.new

      klass = Class.new do
        include Minigun::DSL

        def initialize(worker_uris, items, results, results_mutex)
          @worker_uris = worker_uris
          @items = items
          @results = results
          @results_mutex = results_mutex
        end

        pipeline do
          producer :generate do |output|
            @items.each { |item| output << item }
          end

          in_cluster(worker_uris: @worker_uris, shutdown_on_done: false) do
            processor :tracked_process do |item, output|
              output << item
            end
          end

          consumer :collect do |item|
            @results_mutex.synchronize { @results << item }
          end
        end
      end

      pipeline = klass.new(workers.map { |w| w[:uri] }, items, results, results_mutex)
      pipeline.run

      expect(results.size).to eq(20)
    end
  end

  describe 'Dynamic Cluster Membership' do
    it 'handles new worker joining mid-processing (coordinator mode simulation)' do
      # This test simulates dynamic membership by adding workers to the URI list
      # In production, this would use coordinator mode with register_worker

      initial_workers = start_workers(2, network_sim, delivery_tracker, started_services)
      items = (1..50).map { |i| { id: i, value: i } }
      results = []
      results_mutex = Mutex.new
      worker_uris = initial_workers.map { |w| w[:uri] }

      # Note: Current direct mode doesn't support dynamic membership
      # This test documents that limitation and shows expected behavior

      klass = Class.new do
        include Minigun::DSL

        def initialize(worker_uris, items, results, results_mutex)
          @worker_uris = worker_uris
          @items = items
          @results = results
          @results_mutex = results_mutex
        end

        pipeline do
          producer :generate do |output|
            @items.each { |item| output << item }
          end

          in_cluster(worker_uris: @worker_uris, shutdown_on_done: false) do
            processor :tracked_process do |item, output|
              output << item
            end
          end

          consumer :collect do |item|
            @results_mutex.synchronize { @results << item }
          end
        end
      end

      pipeline = klass.new(worker_uris, items, results, results_mutex)
      pipeline.run

      # With static URIs, only initial workers process items
      expect(results.size).to eq(50)

      # Verify work was only on initial workers
      initial_counts = initial_workers.map { |w| w[:service].get_process_count }
      expect(initial_counts.sum).to eq(50)
    end

    it 'handles worker removal mid-processing gracefully' do
      workers = start_workers(3, network_sim, delivery_tracker, started_services)
      items = (1..20).map { |i| { id: i, value: i } }
      results = []
      results_mutex = Mutex.new

      # Track processed items
      items_processed = 0
      items_mutex = Mutex.new

      # Fail the last worker after first few items
      workers.last[:service].define_singleton_method(:process_item) do |stage_name, item|
        items_mutex.synchronize { items_processed += 1 }

        if items_processed > 5
          # Simulate worker going away
          raise DRb::DRbConnError, 'Worker unavailable'
        end

        @worker.process_item_sync(stage_name, item)
      end

      klass = Class.new do
        include Minigun::DSL

        def initialize(worker_uris, items, results, results_mutex)
          @worker_uris = worker_uris
          @items = items
          @results = results
          @results_mutex = results_mutex
        end

        pipeline do
          producer :generate do |output|
            @items.each { |item| output << item }
          end

          in_cluster(worker_uris: @worker_uris, shutdown_on_done: false) do
            processor :tracked_process do |item, output|
              output << item
            end
          end

          consumer :collect do |item|
            @results_mutex.synchronize { @results << item }
          end
        end
      end

      begin
        pipeline = klass.new(workers.map { |w| w[:uri] }, items, results, results_mutex)
        Timeout.timeout(10) { pipeline.run }
      rescue Minigun::Cluster::Error
        # Expected when worker fails
      end

      # Partial results from before failure
      expect(results.size).to be > 0
    end
  end

  describe 'Delivery Guarantees' do
    # Note: Current implementation provides "at-most-once" semantics
    # Items may be lost on failure, but won't be duplicated

    it 'demonstrates at-most-once delivery (no duplicates on success)' do
      workers = start_workers(2, network_sim, delivery_tracker, started_services)
      items = (1..100).map { |i| { id: i, value: i } }

      # Run multiple times to check for duplicates
      3.times do
        results = []
        results_mutex = Mutex.new
        tracker = DeliveryTracker.new

        klass = Class.new do
          include Minigun::DSL

          def initialize(worker_uris, items, results, results_mutex, tracker)
            @worker_uris = worker_uris
            @items = items
            @results = results
            @results_mutex = results_mutex
            @tracker = tracker
          end

          pipeline do
            producer :generate do |output|
              @items.each do |item|
                @tracker.track_sent(item[:id])
                output << item
              end
            end

            in_cluster(worker_uris: @worker_uris, shutdown_on_done: false) do
              processor :tracked_process do |item, output|
                output << item
              end
            end

            consumer :collect do |item|
              @tracker.track_received(item[:id])
              @results_mutex.synchronize { @results << item }
            end
          end
        end

        pipeline = klass.new(workers.map { |w| w[:uri] }, items, results, results_mutex, tracker)
        pipeline.run

        # Verify no duplicates
        received_ids = results.map { |r| r[:id] }
        expect(received_ids.tally.values.max).to eq(1), 'Duplicate items detected'
      end
    end

    it 'documents potential item loss on worker failure (at-most-once limitation)' do
      workers = start_workers(2, network_sim, delivery_tracker, started_services)
      items = (1..20).map { |i| { id: i, value: i } }
      results = []
      results_mutex = Mutex.new
      tracker = DeliveryTracker.new

      # Fail one worker after some items
      fail_counter = 0
      fail_mutex = Mutex.new

      workers.first[:service].define_singleton_method(:process_item) do |stage_name, item|
        fail_mutex.synchronize { fail_counter += 1 }
        raise DRb::DRbConnError, 'Connection lost' if fail_counter > 3

        @worker.process_item_sync(stage_name, item)
      end

      klass = Class.new do
        include Minigun::DSL

        def initialize(worker_uris, items, results, results_mutex, tracker)
          @worker_uris = worker_uris
          @items = items
          @results = results
          @results_mutex = results_mutex
          @tracker = tracker
        end

        pipeline do
          producer :generate do |output|
            @items.each do |item|
              @tracker.track_sent(item[:id])
              output << item
            end
          end

          in_cluster(worker_uris: @worker_uris, shutdown_on_done: false) do
            processor :tracked_process do |item, output|
              output << item
            end
          end

          consumer :collect do |item|
            @tracker.track_received(item[:id])
            @results_mutex.synchronize { @results << item }
          end
        end
      end

      begin
        pipeline = klass.new(workers.map { |w| w[:uri] }, items, results, results_mutex, tracker)
        Timeout.timeout(10) { pipeline.run }
      rescue Minigun::Cluster::Error
        # Expected
      end

      # Document: items may be lost (at-most-once)
      missing = tracker.missing
      if missing.any?
        # This is expected behavior - documenting it
        expect(missing.size).to be < items.size # Some were processed
      end

      # But never duplicates
      expect(tracker.duplicates).to be_empty
    end
  end

  describe 'Shutdown Behavior' do
    it 'handles shutdown_on_done: true correctly' do
      workers = start_workers(2, network_sim, delivery_tracker, started_services)
      items = (1..10).map { |i| { id: i, value: i } }
      results = []
      results_mutex = Mutex.new

      klass = Class.new do
        include Minigun::DSL

        def initialize(worker_uris, items, results, results_mutex)
          @worker_uris = worker_uris
          @items = items
          @results = results
          @results_mutex = results_mutex
        end

        pipeline do
          producer :generate do |output|
            @items.each { |item| output << item }
          end

          in_cluster(worker_uris: @worker_uris, shutdown_on_done: true) do
            processor :tracked_process do |item, output|
              output << item
            end
          end

          consumer :collect do |item|
            @results_mutex.synchronize { @results << item }
          end
        end
      end

      pipeline = klass.new(workers.map { |w| w[:uri] }, items, results, results_mutex)
      pipeline.run

      # Allow time for shutdown signals
      sleep 0.2

      # Workers should have received shutdown
      workers.each do |w|
        expect(w[:flag][:shutdown]).to be(true), "Worker #{w[:port]} not shutdown"
      end
    end

    it 'handles shutdown_on_done: false correctly' do
      workers = start_workers(2, network_sim, delivery_tracker, started_services)
      items = (1..10).map { |i| { id: i, value: i } }
      results = []
      results_mutex = Mutex.new

      klass = Class.new do
        include Minigun::DSL

        def initialize(worker_uris, items, results, results_mutex)
          @worker_uris = worker_uris
          @items = items
          @results = results
          @results_mutex = results_mutex
        end

        pipeline do
          producer :generate do |output|
            @items.each { |item| output << item }
          end

          in_cluster(worker_uris: @worker_uris, shutdown_on_done: false) do
            processor :tracked_process do |item, output|
              output << item
            end
          end

          consumer :collect do |item|
            @results_mutex.synchronize { @results << item }
          end
        end
      end

      pipeline = klass.new(workers.map { |w| w[:uri] }, items, results, results_mutex)
      pipeline.run

      # Allow time for potential shutdown signals
      sleep 0.2

      # Workers should NOT have received shutdown
      workers.each do |w|
        expect(w[:flag][:shutdown]).to be(false), "Worker #{w[:port]} unexpectedly shutdown"
      end
    end
  end

  describe 'Edge Cases' do
    it 'handles empty work queue' do
      workers = start_workers(2, network_sim, delivery_tracker, started_services)
      items = []
      results = []
      results_mutex = Mutex.new

      klass = Class.new do
        include Minigun::DSL

        def initialize(worker_uris, items, results, results_mutex)
          @worker_uris = worker_uris
          @items = items
          @results = results
          @results_mutex = results_mutex
        end

        pipeline do
          producer :generate do |output|
            @items.each { |item| output << item }
          end

          in_cluster(worker_uris: @worker_uris, shutdown_on_done: false) do
            processor :tracked_process do |item, output|
              output << item
            end
          end

          consumer :collect do |item|
            @results_mutex.synchronize { @results << item }
          end
        end
      end

      pipeline = klass.new(workers.map { |w| w[:uri] }, items, results, results_mutex)
      pipeline.run

      expect(results).to be_empty
    end

    it 'handles single item' do
      workers = start_workers(2, network_sim, delivery_tracker, started_services)
      items = [{ id: 1, value: 42 }]
      results = []
      results_mutex = Mutex.new

      klass = Class.new do
        include Minigun::DSL

        def initialize(worker_uris, items, results, results_mutex)
          @worker_uris = worker_uris
          @items = items
          @results = results
          @results_mutex = results_mutex
        end

        pipeline do
          producer :generate do |output|
            @items.each { |item| output << item }
          end

          in_cluster(worker_uris: @worker_uris, shutdown_on_done: false) do
            processor :tracked_process do |item, output|
              output << item
            end
          end

          consumer :collect do |item|
            @results_mutex.synchronize { @results << item }
          end
        end
      end

      pipeline = klass.new(workers.map { |w| w[:uri] }, items, results, results_mutex)
      pipeline.run

      expect(results.size).to eq(1)
      expect(results.first[:id]).to eq(1)
    end

    it 'handles large items (serialization test)' do
      workers = start_workers(2, network_sim, delivery_tracker, started_services)
      large_data = 'x' * 100_000
      items = [{ id: 1, value: 1, data: large_data }]
      results = []
      results_mutex = Mutex.new

      klass = Class.new do
        include Minigun::DSL

        def initialize(worker_uris, items, results, results_mutex)
          @worker_uris = worker_uris
          @items = items
          @results = results
          @results_mutex = results_mutex
        end

        pipeline do
          producer :generate do |output|
            @items.each { |item| output << item }
          end

          in_cluster(worker_uris: @worker_uris, shutdown_on_done: false) do
            processor :tracked_process do |item, output|
              output << item
            end
          end

          consumer :collect do |item|
            @results_mutex.synchronize { @results << item }
          end
        end
      end

      pipeline = klass.new(workers.map { |w| w[:uri] }, items, results, results_mutex)
      pipeline.run

      expect(results.size).to eq(1)
      # The large data may or may not be preserved depending on worker implementation
      # The key test is that serialization doesn't fail
      result = results.first
      expect(result[:id]).to eq(1)
      expect(result[:value]).to eq(2) # Doubled by tracked worker
    end

    it 'handles rapid item production' do
      workers = start_workers(3, network_sim, delivery_tracker, started_services)
      items = (1..200).map { |i| { id: i, value: i } }
      results = []
      results_mutex = Mutex.new

      klass = Class.new do
        include Minigun::DSL

        def initialize(worker_uris, items, results, results_mutex)
          @worker_uris = worker_uris
          @items = items
          @results = results
          @results_mutex = results_mutex
        end

        pipeline do
          producer :generate do |output|
            @items.each { |item| output << item }
          end

          in_cluster(worker_uris: @worker_uris, shutdown_on_done: false) do
            processor :tracked_process do |item, output|
              output << item
            end
          end

          consumer :collect do |item|
            @results_mutex.synchronize { @results << item }
          end
        end
      end

      pipeline = klass.new(workers.map { |w| w[:uri] }, items, results, results_mutex)

      start_time = Time.now
      pipeline.run
      elapsed = Time.now - start_time

      expect(results.size).to eq(200)
      expect(elapsed).to be < 30 # Should complete in reasonable time
    end

    it 'handles workers with varying processing speeds' do
      workers = start_workers(3, network_sim, delivery_tracker, started_services)

      # Add different delays to workers
      network_sim.add_delay(workers[0][:service].worker_id, 20)  # 20ms
      network_sim.add_delay(workers[1][:service].worker_id, 50)  # 50ms
      network_sim.add_delay(workers[2][:service].worker_id, 5)   # 5ms

      items = (1..30).map { |i| { id: i, value: i } }
      results = []
      results_mutex = Mutex.new

      klass = Class.new do
        include Minigun::DSL

        def initialize(worker_uris, items, results, results_mutex)
          @worker_uris = worker_uris
          @items = items
          @results = results
          @results_mutex = results_mutex
        end

        pipeline do
          producer :generate do |output|
            @items.each { |item| output << item }
          end

          in_cluster(worker_uris: @worker_uris, shutdown_on_done: false) do
            processor :tracked_process do |item, output|
              output << item
            end
          end

          consumer :collect do |item|
            @results_mutex.synchronize { @results << item }
          end
        end
      end

      pipeline = klass.new(workers.map { |w| w[:uri] }, items, results, results_mutex)
      pipeline.run

      expect(results.size).to eq(30)

      # Verify all workers processed items
      counts = workers.map { |w| w[:service].get_process_count }
      expect(counts.sum).to eq(30)
    end
  end

  describe 'Concurrency Stress Tests' do
    it 'handles high concurrency with many items' do
      workers = start_workers(4, network_sim, delivery_tracker, started_services)
      items = (1..100).map { |i| { id: i, value: i } }
      results = []
      results_mutex = Mutex.new

      klass = Class.new do
        include Minigun::DSL

        def initialize(worker_uris, items, results, results_mutex)
          @worker_uris = worker_uris
          @items = items
          @results = results
          @results_mutex = results_mutex
        end

        pipeline do
          producer :generate do |output|
            @items.each { |item| output << item }
          end

          in_cluster(worker_uris: @worker_uris, shutdown_on_done: false) do
            processor :tracked_process do |item, output|
              output << item
            end
          end

          consumer :collect do |item|
            @results_mutex.synchronize { @results << item }
          end
        end
      end

      pipeline = klass.new(workers.map { |w| w[:uri] }, items, results, results_mutex)

      Timeout.timeout(30) { pipeline.run }

      expect(results.size).to eq(100)

      # Verify no duplicates
      ids = results.map { |r| r[:id] }
      expect(ids.uniq.size).to eq(ids.size)
    end

    it 'handles multiple sequential pipeline runs' do
      workers = start_workers(2, network_sim, delivery_tracker, started_services)
      all_results = []

      3.times do |run|
        items = (1..20).map { |i| { id: (run * 100) + i, value: i } }
        results = []
        results_mutex = Mutex.new

        klass = Class.new do
          include Minigun::DSL

          def initialize(worker_uris, items, results, results_mutex)
            @worker_uris = worker_uris
            @items = items
            @results = results
            @results_mutex = results_mutex
          end

          pipeline do
            producer :generate do |output|
              @items.each { |item| output << item }
            end

            in_cluster(worker_uris: @worker_uris, shutdown_on_done: false) do
              processor :tracked_process do |item, output|
                output << item
              end
            end

            consumer :collect do |item|
              @results_mutex.synchronize { @results << item }
            end
          end
        end

        pipeline = klass.new(workers.map { |w| w[:uri] }, items, results, results_mutex)
        pipeline.run

        expect(results.size).to eq(20)
        all_results.concat(results)
      end

      expect(all_results.size).to eq(60)
    end
  end

  describe 'At-Least-Once Delivery Mode' do
    it 'retries items when worker fails' do
      workers = start_workers(2, network_sim, delivery_tracker, started_services)
      items = (1..10).map { |i| { id: i, value: i } }
      results = []
      results_mutex = Mutex.new
      tracker = DeliveryTracker.new

      # First worker fails for first 3 items, then works
      fail_counter = 0
      fail_mutex = Mutex.new
      workers.first[:service].define_singleton_method(:process_item) do |stage_name, item|
        should_fail = fail_mutex.synchronize do
          fail_counter += 1
          fail_counter <= 3
        end
        raise DRb::DRbConnError, 'Worker crashed' if should_fail

        @worker.process_item_sync(stage_name, item)
      end

      klass = Class.new do
        include Minigun::DSL

        def initialize(worker_uris, items, results, results_mutex, tracker)
          @worker_uris = worker_uris
          @items = items
          @results = results
          @results_mutex = results_mutex
          @tracker = tracker
        end

        pipeline do
          producer :generate do |output|
            @items.each do |item|
              @tracker.track_sent(item[:id])
              output << item
            end
          end

          in_cluster(worker_uris: @worker_uris, delivery_mode: :at_least_once, max_retries: 5) do
            processor :tracked_process do |item, output|
              output << item
            end
          end

          consumer :collect do |item|
            @tracker.track_received(item[:id])
            @results_mutex.synchronize { @results << item }
          end
        end
      end

      pipeline = klass.new(workers.map { |w| w[:uri] }, items, results, results_mutex, tracker)
      Timeout.timeout(15) { pipeline.run }

      # All items should be delivered
      expect(tracker.missing).to be_empty, "Missing items: #{tracker.missing}"
      expect(results.size).to be >= 10 # At least all items (may have duplicates)
    end

    it 'delivers all items when one worker is completely unavailable' do
      workers = start_workers(2, network_sim, delivery_tracker, started_services)
      items = (1..15).map { |i| { id: i, value: i } }
      results = []
      results_mutex = Mutex.new
      tracker = DeliveryTracker.new

      # First worker always fails
      workers.first[:service].define_singleton_method(:process_item) do |_stage_name, _item|
        raise DRb::DRbConnError, 'Worker completely down'
      end

      klass = Class.new do
        include Minigun::DSL

        def initialize(worker_uris, items, results, results_mutex, tracker)
          @worker_uris = worker_uris
          @items = items
          @results = results
          @results_mutex = results_mutex
          @tracker = tracker
        end

        pipeline do
          producer :generate do |output|
            @items.each do |item|
              @tracker.track_sent(item[:id])
              output << item
            end
          end

          in_cluster(worker_uris: @worker_uris, delivery_mode: :at_least_once, max_retries: 5) do
            processor :tracked_process do |item, output|
              output << item
            end
          end

          consumer :collect do |item|
            @tracker.track_received(item[:id])
            @results_mutex.synchronize { @results << item }
          end
        end
      end

      pipeline = klass.new(workers.map { |w| w[:uri] }, items, results, results_mutex, tracker)
      Timeout.timeout(20) { pipeline.run }

      # All items delivered (via the working worker)
      expect(tracker.missing).to be_empty, "Missing items: #{tracker.missing}"
      received_ids = results.map { |r| r[:id] }.uniq.sort
      expect(received_ids).to eq((1..15).to_a)
    end

    it 'eventually gives up after max_retries exceeded' do
      workers = start_workers(2, network_sim, delivery_tracker, started_services)
      items = (1..5).map { |i| { id: i, value: i } }
      results = []
      results_mutex = Mutex.new

      # Both workers always fail
      workers.each do |w|
        w[:service].define_singleton_method(:process_item) do |_stage_name, _item|
          raise DRb::DRbConnError, 'All workers down'
        end
      end

      klass = Class.new do
        include Minigun::DSL

        def initialize(worker_uris, items, results, results_mutex)
          @worker_uris = worker_uris
          @items = items
          @results = results
          @results_mutex = results_mutex
        end

        pipeline do
          producer :generate do |output|
            @items.each { |item| output << item }
          end

          in_cluster(worker_uris: @worker_uris, delivery_mode: :at_least_once, max_retries: 2) do
            processor :tracked_process do |item, output|
              output << item
            end
          end

          consumer :collect do |item|
            @results_mutex.synchronize { @results << item }
          end
        end
      end

      pipeline = klass.new(workers.map { |w| w[:uri] }, items, results, results_mutex)

      # Should complete (not hang) even with all failures
      Timeout.timeout(15) { pipeline.run }

      # No results (all workers failed)
      expect(results).to be_empty
    end

    it 'allows duplicates in at-least-once mode during retries' do
      workers = start_workers(2, network_sim, delivery_tracker, started_services)
      items = (1..10).map { |i| { id: i, value: i } }
      results = []
      results_mutex = Mutex.new

      # First worker processes but then "crashes" before returning
      # (simulating crash after processing but before ack)
      process_count = 0
      process_mutex = Mutex.new
      workers.first[:service].define_singleton_method(:process_item) do |stage_name, item|
        # Process item
        result = @worker.process_item_sync(stage_name, item)

        # Sometimes "crash" after processing (simulating network failure on response)
        should_crash = process_mutex.synchronize do
          process_count += 1
          process_count <= 3
        end
        raise DRb::DRbConnError, 'Crashed after processing' if should_crash

        result
      end

      klass = Class.new do
        include Minigun::DSL

        def initialize(worker_uris, items, results, results_mutex)
          @worker_uris = worker_uris
          @items = items
          @results = results
          @results_mutex = results_mutex
        end

        pipeline do
          producer :generate do |output|
            @items.each { |item| output << item }
          end

          # Note: In a real scenario, you'd want idempotent processing
          in_cluster(worker_uris: @worker_uris, delivery_mode: :at_least_once, max_retries: 3) do
            processor :tracked_process do |item, output|
              output << item
            end
          end

          consumer :collect do |item|
            @results_mutex.synchronize { @results << item }
          end
        end
      end

      pipeline = klass.new(workers.map { |w| w[:uri] }, items, results, results_mutex)
      Timeout.timeout(15) { pipeline.run }

      # All items should be present
      received_ids = results.map { |r| r[:id] }
      expect(received_ids.uniq.sort).to eq((1..10).to_a)

      # Due to at-least-once semantics, duplicates are expected when worker
      # crashes after processing. This is documented behavior.
    end

    it 'validates delivery_mode parameter' do
      # Create instance and trigger pipeline evaluation which validates delivery_mode
      klass = Class.new do
        include Minigun::DSL

        pipeline do
          producer :gen do |output|
            output << 1
          end

          in_cluster(worker_uris: ['druby://localhost:9999'], delivery_mode: :invalid) do
            consumer :sink do |_item|
            end
          end
        end
      end

      instance = klass.new
      # Trigger pipeline evaluation which should raise
      expect { instance.run }.to raise_error(ArgumentError, /Invalid delivery_mode/)
    end
  end
end
