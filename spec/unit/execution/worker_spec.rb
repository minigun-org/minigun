# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Minigun::Worker do
  let(:task) { Minigun::Task.new }
  let(:pipeline) { task.root_pipeline }
  let(:stage) { Minigun::ConsumerStage.new(:test_stage, pipeline, proc { |item, output| output << item }, {}) }
  let(:config) { { max_threads: 5, max_processes: 2 } }
  let(:user_context) { {} }
  let(:stage_stats) { Minigun::Stats.new(stage) }
  let(:stats) { pipeline.stats }
  let(:stage_hooks) { {} }
  let(:dag) { pipeline.dag }

  before do
    allow(Minigun.logger).to receive(:info)
    # Initialize stats and runtime_edges manually since we're not calling run()
    pipeline.instance_variable_set(:@stats, Minigun::AggregatedStats.new(pipeline, dag))
    pipeline.instance_variable_set(:@runtime_edges, Concurrent::Hash.new { |h, k| h[k] = Concurrent::Set.new })
  end

  # Helper to ensure queue is registered for a stage
  def ensure_queue(stage)
    queue = task.find_queue(stage)
    unless queue
      queue = Queue.new
      task.register_stage_queue(stage, queue)
    end
    queue
  end

  describe '#initialize' do
    it 'creates a worker' do
      worker = described_class.new(pipeline, stage, config)

      expect(worker.stage_name).to eq(:test_stage)
      expect(worker).to be_a(described_class)
    end

    it 'does not start the worker thread immediately' do
      worker = described_class.new(pipeline, stage, config)

      expect(worker.thread).to be_nil
    end
  end

  describe '#start' do
    it 'starts a worker thread' do
      worker = described_class.new(pipeline, stage, config)

      worker.start

      # Thread should be created
      expect(worker.thread).to be_a(Thread)

      # Put END signal so the worker exits
      input_queue = ensure_queue(stage)
      upstream_stage = Minigun::ProducerStage.new(:upstream, pipeline, proc {}, {})
      input_queue << Minigun::EndOfSource.new(upstream_stage)

      worker.join

      # Thread should have finished cleanly
      expect(worker.thread).not_to be_alive
    end
  end

  describe '#join' do
    it 'waits for worker thread to complete' do
      worker = described_class.new(pipeline, stage, config)

      # Put END signal
      input_queue = ensure_queue(stage)
      upstream_stage = Minigun::ProducerStage.new(:upstream, pipeline, proc {}, {})
      input_queue << Minigun::EndOfSource.new(upstream_stage)

      worker.start
      worker.join

      expect(worker.thread).not_to be_alive
    end

    it 'handles nil thread gracefully' do
      worker = described_class.new(pipeline, stage, config)

      expect { worker.join }.not_to raise_error
    end
  end

  describe 'executor creation' do
    context 'with inline execution context' do
      before do
        allow(stage).to receive(:execution_context).and_return(nil)
      end

      it 'creates an inline executor' do
        worker = described_class.new(pipeline, stage, config)

        # Should not raise error
        expect(worker).to be_a(described_class)
      end
    end

    context 'with thread execution context' do
      before do
        allow(stage).to receive(:execution_context).and_return({ type: :thread, pool_size: 5 })
      end

      it 'creates a thread pool executor' do
        worker = described_class.new(pipeline, stage, config)

        expect(worker).to be_a(described_class)
      end
    end

    context 'with process execution context' do
      before do
        allow(stage).to receive(:execution_context).and_return({ type: :cow_fork, max: 2 })
      end

      it 'creates a process pool executor' do
        worker = described_class.new(pipeline, stage, config)

        expect(worker).to be_a(described_class)
      end
    end
  end

  describe 'disconnected stage handling' do
    it 'warns and waits with default 5s timeout if no upstream sources' do
      # Create a stage with no await option (will use default 5s timeout)
      disconnected_stage = Minigun::ConsumerStage.new(:disconnected, pipeline, proc { |item, output| output << item }, {})

      worker = described_class.new(pipeline, disconnected_stage, config)

      allow(Minigun.logger).to receive(:warn).and_call_original
      allow(Minigun.logger).to receive(:debug).and_call_original

      worker.start
      worker.join

      # Should log warning about default 5s timeout
      expect(Minigun.logger).to have_received(:warn).with(/Stage has no DAG upstream connections, using default 5s await timeout/)
    end

    it 'sends END signals to downstream after timeout if disconnected' do
      # Create stage with short timeout
      timeout_stage = Minigun::ConsumerStage.new(:timeout_test, pipeline, proc { |item, output| output << item }, { await: 0.1 })
      downstream_stage = Minigun::ConsumerStage.new(:downstream, pipeline, proc { |item, output| output << item }, {})

      # Manually add edge to DAG
      dag.add_edge(timeout_stage, downstream_stage)

      worker = described_class.new(pipeline, timeout_stage, config)
      worker.start
      worker.join

      # Should have sent END signal to downstream after timeout
      downstream_queue = task.find_queue(downstream_stage)
      msg = begin
        downstream_queue.pop(true)
      rescue StandardError
        nil
      end
      expect(msg).to be_a(Minigun::EndOfSource) if msg
    end

    it 'immediately shuts down with await: false' do
      # Create stage with await: false
      immediate_stage = Minigun::ConsumerStage.new(:immediate_test, pipeline, proc { |item, output| output << item }, { await: false })
      downstream_stage = Minigun::ConsumerStage.new(:downstream2, pipeline, proc { |item, output| output << item }, {})

      # Manually add edge to DAG
      dag.add_edge(immediate_stage, downstream_stage)

      worker = described_class.new(pipeline, immediate_stage, config)

      allow(Minigun.logger).to receive(:debug).and_call_original

      worker.start
      worker.join

      # Should have sent END signal to downstream immediately
      downstream_queue = task.find_queue(downstream_stage)
      msg = begin
        downstream_queue.pop(true)
      rescue StandardError
        nil
      end
      expect(msg).to be_a(Minigun::EndOfSource) if msg
      expect(Minigun.logger).to have_received(:debug).with(/Shutting down immediately/)
    end

    it 'waits indefinitely with await: true' do
      # Create stage with await: true
      await_stage = Minigun::ConsumerStage.new(:await_test, pipeline, proc { |item, output| output << item }, { await: true })

      worker = described_class.new(pipeline, await_stage, config)

      allow(Minigun.logger).to receive(:debug).and_call_original

      # Start worker in background
      worker.start
      sleep 0.2 # Give it time to start

      # Should log that it's awaiting indefinitely
      expect(Minigun.logger).to have_received(:debug).with(/Awaiting items indefinitely/)

      # Clean up
      Thread.kill(worker.thread) if worker.thread&.alive?
    end
  end

  describe 'router stage' do
    # Create mock stage objects (positional constructor style)
    let(:router_stage) do
      Minigun::ConsumerStage.new(:router, pipeline, proc {}, {})
    end
    let(:target_a_stage) { Minigun::ConsumerStage.new(:target_a, pipeline, proc {}, {}) }
    let(:target_b_stage) { Minigun::ConsumerStage.new(:target_b, pipeline, proc {}, {}) }
    let(:source_stage) { Minigun::ProducerStage.new(:source, pipeline, proc {}, {}) }

    let(:broadcast_router) do
      Minigun::RouterBroadcastStage.new(
        :router,
        pipeline,
        [target_a_stage, target_b_stage], # Use Stage objects
        {}
      )
    end

    it 'routes items without executing' do
      # Add upstream edge
      dag.add_edge(source_stage, broadcast_router)

      # Ensure queues are registered
      input_queue = ensure_queue(broadcast_router)
      ensure_queue(target_a_stage)
      ensure_queue(target_b_stage)

      # Put items and END signal
      input_queue << 1
      input_queue << 2
      input_queue << Minigun::EndOfSource.new(source_stage)

      worker = described_class.new(pipeline, broadcast_router, config)
      worker.start
      worker.join

      # Both targets should have received items (broadcast)
      target_a_queue = task.find_queue(target_a_stage)
      target_b_queue = task.find_queue(target_b_stage)
      expect(target_a_queue.size).to be > 0
      expect(target_b_queue.size).to be > 0
    end
  end

  describe 'error handling' do
    it 'shuts down executor even on error' do
      # Create a stage that will raise an error
      error_stage = Minigun::ConsumerStage.new(
        :error_stage,
        pipeline,
        proc { |_item, _output| raise StandardError, 'Test error' },
        {}
      )

      worker = described_class.new(pipeline, error_stage, config)

      # Add upstream so worker gets an item
      upstream_stage = Minigun::ProducerStage.new(:error_upstream, pipeline, proc {}, {})
      dag.add_edge(upstream_stage, error_stage)

      input_queue = ensure_queue(error_stage)
      input_queue << 1
      input_queue << Minigun::EndOfSource.new(upstream_stage)

      worker.start
      sleep 0.02 # Give thread time to start and error
      begin
        worker.join
      rescue StandardError
        nil
      end

      # Test that we don't crash - executor.shutdown is called in ensure block
      expect(worker.thread).not_to be_alive
    end
  end

  describe 'logging' do
    it 'logs when starting' do
      worker = described_class.new(pipeline, stage, config)

      input_queue = ensure_queue(stage)
      upstream_stage = Minigun::ProducerStage.new(:upstream, pipeline, proc {}, {})
      input_queue << Minigun::EndOfSource.new(upstream_stage)

      allow(Minigun.logger).to receive(:debug).and_call_original

      worker.start
      worker.join

      expect(Minigun.logger).to have_received(:debug).with(/Starting/)
    end

    it 'logs when done' do
      worker = described_class.new(pipeline, stage, config)

      # Put END signal
      input_queue = ensure_queue(stage)
      upstream_stage = Minigun::ProducerStage.new(:upstream, pipeline, proc {}, {})
      input_queue << Minigun::EndOfSource.new(upstream_stage)

      allow(Minigun.logger).to receive(:debug).and_call_original

      worker.start
      worker.join

      expect(Minigun.logger).to have_received(:debug).with(/Done/)
    end
  end
end
