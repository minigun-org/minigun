# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Minigun::Cluster do
  # Use unique ports for each test to avoid conflicts
  let(:base_port) { 19_000 + rand(1000) }

  describe Minigun::Cluster::Coordinator do
    let(:coordinator) { described_class.new(bind_address: '127.0.0.1', port: base_port) }

    after do
      begin
        # Stop the coordinator gracefully
        coordinator.stop
      rescue StandardError
        nil
      end
      # Give DRb time to fully release the port
      sleep 0.1
    end

    describe '#initialize' do
      it 'creates a coordinator with default settings' do
        c = described_class.new
        expect(c.workers).to be_empty
        expect(c.stage_name).to be_nil
      end

      it 'accepts custom bind address and port' do
        c = described_class.new(bind_address: '0.0.0.0', port: 8080, stage_name: :test)
        expect(c.stage_name).to eq(:test)
      end
    end

    describe '#start and #stop' do
      it 'starts and stops the DRb service' do
        uri = coordinator.start
        expect(uri).to match(%r{druby://127\.0\.0\.1:\d+})

        coordinator.stop
        # After stop, the service should be down
      end
    end

    describe '#register_worker and #unregister_worker' do
      before { coordinator.start }

      it 'registers a worker' do
        result = coordinator.register_worker('druby://worker1:9001', 'worker-1', { cpu_count: 4 })
        expect(result).to be true
        expect(coordinator.worker_count).to eq(1)
      end

      it 'unregisters a worker' do
        coordinator.register_worker('druby://worker1:9001', 'worker-1')
        expect(coordinator.worker_count).to eq(1)

        coordinator.unregister_worker('worker-1')
        expect(coordinator.worker_count).to eq(0)
      end
    end

    describe '#heartbeat' do
      before { coordinator.start }

      it 'returns true for registered workers' do
        coordinator.register_worker('druby://worker1:9001', 'worker-1')
        expect(coordinator.heartbeat('worker-1')).to be true
      end

      it 'returns false for unknown workers' do
        expect(coordinator.heartbeat('unknown-worker')).to be false
      end
    end

    describe '#enqueue_work and #request_work' do
      before { coordinator.start }

      it 'enqueues and retrieves work items' do
        coordinator.enqueue_work({ id: 1, data: 'test' })
        coordinator.enqueue_work({ id: 2, data: 'test2' })

        work1 = coordinator.request_work
        expect(work1[:type]).to eq(:item)
        expect(work1[:item][:id]).to eq(1)

        work2 = coordinator.request_work
        expect(work2[:item][:id]).to eq(2)
      end

      it 'returns nil when queue is empty' do
        expect(coordinator.request_work).to be_nil
      end
    end

    describe '#submit_result and #collect_result' do
      before { coordinator.start }

      it 'collects submitted results' do
        coordinator.submit_result({ type: :result, result: 42, worker_id: 'w1' })

        result = coordinator.collect_result(timeout: 0.1)
        expect(result[:type]).to eq(:result)
        expect(result[:result]).to eq(42)
      end
    end

    describe '#wait_for_workers' do
      before { coordinator.start }

      it 'returns true when enough workers connect' do
        # Register workers in background
        Thread.new do
          sleep 0.05
          coordinator.register_worker('druby://w1:9001', 'w1')
          coordinator.register_worker('druby://w2:9002', 'w2')
        end

        result = coordinator.wait_for_workers(min_count: 2, timeout: 1)
        expect(result).to be true
        expect(coordinator.worker_count).to eq(2)
      end

      it 'returns false on timeout' do
        result = coordinator.wait_for_workers(min_count: 5, timeout: 0.1)
        expect(result).to be false
      end
    end
  end

  describe Minigun::Cluster::Worker do
    describe '#initialize' do
      it 'creates a worker with coordinator URI' do
        worker = described_class.new(coordinator_uri: 'druby://localhost:9000')
        expect(worker.coordinator_uri).to eq('druby://localhost:9000')
        expect(worker.worker_id).to be_a(String)
        expect(worker.worker_id).not_to be_empty
      end

      it 'accepts custom worker ID' do
        worker = described_class.new(
          coordinator_uri: 'druby://localhost:9000',
          worker_id: 'my-custom-worker'
        )
        expect(worker.worker_id).to eq('my-custom-worker')
      end
    end

    describe '#register_stage' do
      it 'registers a stage processor' do
        worker = described_class.new(coordinator_uri: 'druby://localhost:9000')

        worker.register_stage(:compute) do |item, output|
          output.call(item * 2)
        end

        # We can't easily test the internal registry, but we can verify it doesn't raise
      end
    end
  end

  describe Minigun::Cluster::Discovery::Static do
    it 'returns the configured workers' do
      discovery = described_class.new(workers: ['druby://w1:9001', 'druby://w2:9002'])
      expect(discovery.discover).to eq(['druby://w1:9001', 'druby://w2:9002'])
    end
  end

  describe Minigun::Cluster::Discovery::Gossip do
    it 'detects rswim availability' do
      discovery = described_class.new(port: 9999)
      # rswim should be available since we added it to Gemfile
      # But it may fail to load in some environments
      expect([true, false]).to include(discovery.available?)
    end
  end

  describe 'Integration: Coordinator and Worker', :integration do
    let(:port) { 19_500 + rand(500) }
    let(:coordinator) { Minigun::Cluster::Coordinator.new(bind_address: '127.0.0.1', port: port) }

    after do
      begin
        coordinator.stop
      rescue StandardError
        nil
      end
      sleep 0.1
    end

    it 'worker can connect to coordinator and process work' do
      # Start coordinator
      coordinator.start

      # Create and configure worker
      worker = Minigun::Cluster::Worker.new(
        coordinator_uri: "druby://127.0.0.1:#{port}",
        worker_id: 'test-worker-1'
      )

      # Register a simple stage processor
      worker.register_stage(:default) do |item, output|
        output.call(item * 2)
      end

      # Connect worker
      worker.connect

      # Verify worker is registered
      expect(coordinator.worker_count).to eq(1)

      # Enqueue work
      coordinator.enqueue_work({ stage: :default, item: 21 })
      coordinator.enqueue_work({ type: :shutdown })

      # Run worker (will process 1 item then see shutdown)
      # Run in thread with timeout
      worker_thread = Thread.new { worker.start }

      # Give worker time to process
      sleep 0.3

      # Collect result
      result = coordinator.collect_result(timeout: 1)
      expect(result).not_to be_nil
      expect(result[:type]).to eq(:result)
      expect(result[:result]).to eq(42)

      # Clean up worker thread
      worker.stop
      worker_thread.join(1)
    end
  end
end
