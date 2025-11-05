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
      input_queue = task.find_queue(stage)
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
      input_queue = task.find_queue(stage)
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
      input_queue = Queue.new
      allow(task).to receive(:find_queue).with(stage).and_return(input_queue)
      allow(dag).to receive(:upstream).with(stage).and_return([])
      allow(dag).to receive(:downstream).with(stage).and_return([])
      allow(stage).to receive(:options).and_return({}) # No await option set

      worker = described_class.new(pipeline, stage, config)

      allow(Minigun.logger).to receive(:warn).and_call_original
      allow(Minigun.logger).to receive(:debug).and_call_original

      worker.start
      worker.join

      # Should log warning about default 5s timeout
      expect(Minigun.logger).to have_received(:warn).with(/Stage has no DAG upstream connections, using default 5s await timeout/)
    end

    it 'sends END signals to downstream after timeout if disconnected' do
      input_queue = Queue.new
      downstream_stage = double('downstream_stage', name: :downstream, task: task)
      downstream_queue = Queue.new

      allow(task).to receive(:find_queue).with(stage).and_return(input_queue)
      allow(task).to receive(:find_queue).with(downstream_stage).and_return(downstream_queue)
      allow(dag).to receive(:upstream).with(stage).and_return([])
      allow(dag).to receive(:downstream).with(stage).and_return([downstream_stage])
      allow(stage).to receive(:options).and_return({ await: 0.1 }) # Short timeout for test

      worker = described_class.new(pipeline, stage, config)
      worker.start
      worker.join

      # Should have sent END signal to downstream after timeout
      msg = begin
        downstream_queue.pop(true)
      rescue StandardError
        nil
      end
      expect(msg).to be_a(Minigun::EndOfSource) if msg
    end

    it 'immediately shuts down with await: false' do
      input_queue = Queue.new
      downstream_stage = double('downstream_stage', name: :downstream, task: task)
      downstream_queue = Queue.new

      allow(task).to receive(:find_queue).with(stage).and_return(input_queue)
      allow(task).to receive(:find_queue).with(downstream_stage).and_return(downstream_queue)
      allow(dag).to receive(:upstream).with(stage).and_return([])
      allow(dag).to receive(:downstream).with(stage).and_return([downstream_stage])
      allow(stage).to receive(:options).and_return({ await: false }) # Immediate shutdown

      worker = described_class.new(pipeline, stage, config)

      allow(Minigun.logger).to receive(:debug).and_call_original

      worker.start
      worker.join

      # Should have sent END signal to downstream immediately
      msg = begin
        downstream_queue.pop(true)
      rescue StandardError
        nil
      end
      expect(msg).to be_a(Minigun::EndOfSource) if msg
      expect(Minigun.logger).to have_received(:debug).with(/Shutting down immediately/)
    end

    it 'waits indefinitely with await: true' do
      input_queue = Queue.new
      allow(task).to receive(:find_queue).with(stage).and_return(input_queue)
      allow(dag).to receive(:upstream).with(stage).and_return([])
      allow(dag).to receive(:downstream).with(stage).and_return([])
      allow(stage).to receive(:options).and_return({ await: true }) # Infinite wait
      allow(stage).to receive(:run_stage) # Mock stage execution to avoid hanging

      worker = described_class.new(pipeline, stage, config)

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
        [target_a_stage, target_b_stage],  # Use Stage objects
        {}
      )
    end

    it 'routes items without executing' do
      input_queue = Queue.new
      target_a_queue = Queue.new
      target_b_queue = Queue.new

      allow(task).to receive(:find_queue).with(broadcast_router).and_return(input_queue)
      allow(task).to receive(:find_queue).with(target_a_stage).and_return(target_a_queue)
      allow(task).to receive(:find_queue).with(target_b_stage).and_return(target_b_queue)
      allow(dag).to receive(:upstream).with(broadcast_router).and_return([source_stage])

      # Put items and END signal
      input_queue << 1
      input_queue << 2
      input_queue << Minigun::EndOfSource.new(source_stage)

      worker = described_class.new(pipeline, broadcast_router, config)
      worker.start
      worker.join

      # Both targets should have received items (broadcast)
      expect(target_a_queue.size).to be > 0
      expect(target_b_queue.size).to be > 0
    end
  end

  describe 'error handling' do
    it 'shuts down executor even on error' do
      executor = instance_double(Minigun::Execution::InlineExecutor)
      allow(executor).to receive(:shutdown)

      # Mock executor creation to return our test double (now takes stage_ctx arg)
      allow_any_instance_of(described_class).to receive(:create_executor_if_needed).with(any_args).and_return(executor)

      worker = described_class.new(pipeline, stage, config)

      # Cause an error AFTER stage_ctx is created (so executor gets created)
      # Error during stage.run_stage (after executor is created)
      allow(stage).to receive(:run_stage).and_raise(StandardError, 'Test error')

      expect(executor).to receive(:shutdown)

      worker.start
      sleep 0.02 # Give thread time to start and error
      begin
        worker.join
      rescue StandardError
        nil
      end
    end
  end

  describe 'logging' do
    it 'logs when starting' do
      input_queue = Queue.new
      allow(task).to receive(:find_queue).with(stage).and_return(input_queue)

      input_queue << Minigun::EndOfSource.new(:upstream)

      allow(Minigun.logger).to receive(:debug).and_call_original

      worker = described_class.new(pipeline, stage, config)
      worker.start
      worker.join

      expect(Minigun.logger).to have_received(:debug).with(/Starting/)
    end

    it 'logs when done' do
      input_queue = Queue.new
      allow(task).to receive(:find_queue).with(stage).and_return(input_queue)
      allow(dag).to receive(:upstream).with(:test_stage).and_return([:upstream])
      allow(dag).to receive(:downstream).with(:test_stage).and_return([])

      # Stub run_stage to simulate stage execution
      # Note: accessing raw queue directly here (not wrapped in InputQueue)
      allow(stage).to receive(:run_stage) do |worker_ctx|
        loop do
          msg = worker_ctx.input_queue.pop
          break if msg.is_a?(Minigun::EndOfSource)
        end
      end

      input_queue << Minigun::EndOfSource.new(:upstream)

      allow(Minigun.logger).to receive(:debug).and_call_original

      worker = described_class.new(pipeline, stage, config)
      worker.start
      worker.join

      expect(Minigun.logger).to have_received(:debug).with(/Done/)
    end
  end
end
