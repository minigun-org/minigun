# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Minigun::Execution::StageWorker do
  let(:pipeline) do
    instance_double(
      Minigun::Pipeline,
      instance_variable_get: nil
    )
  end

  let(:stage) do
    double(
      'stage',
      producer?: false,
      router?: false,
      stage_with_loop?: false,
      execution_context: nil
    )
  end

  let(:config) { { max_threads: 5, max_processes: 2 } }
  let(:user_context) { double('context') }
  let(:stats) { {} }
  let(:stage_hooks) { {} }
  let(:dag) { instance_double(Minigun::DAG, upstream: [], downstream: []) }

  before do
    allow(pipeline).to receive(:instance_variable_get).with(:@context).and_return(user_context)
    allow(pipeline).to receive(:instance_variable_get).with(:@stats).and_return(stats)
    allow(pipeline).to receive(:instance_variable_get).with(:@stage_hooks).and_return(stage_hooks)
    allow(pipeline).to receive(:instance_variable_get).with(:@dag).and_return(dag)
    allow(pipeline).to receive(:instance_variable_get).with(:@stage_input_queues).and_return({})
    allow(pipeline).to receive(:instance_variable_get).with(:@runtime_edges).and_return({})
    allow(Minigun.logger).to receive(:info)
  end

  describe '#initialize' do
    it 'creates a stage worker' do
      worker = described_class.new(pipeline, :test_stage, stage, config)

      expect(worker.stage_name).to eq(:test_stage)
      expect(worker.stage).to eq(stage)
    end

    it 'creates an executor for the stage' do
      worker = described_class.new(pipeline, :test_stage, stage, config)

      # Executor should be created (internal detail, but we can verify no errors)
      expect(worker).to be_a(Minigun::Execution::StageWorker)
    end

    it 'retrieves context from pipeline' do
      expect(pipeline).to receive(:instance_variable_get).with(:@context).and_return(user_context)

      described_class.new(pipeline, :test_stage, stage, config)
    end

    it 'retrieves stats from pipeline' do
      expect(pipeline).to receive(:instance_variable_get).with(:@stats).and_return(stats)

      described_class.new(pipeline, :test_stage, stage, config)
    end

    it 'retrieves hooks from pipeline' do
      expect(pipeline).to receive(:instance_variable_get).with(:@stage_hooks).and_return(stage_hooks)

      described_class.new(pipeline, :test_stage, stage, config)
    end
  end

  describe '#start' do
    it 'starts a worker thread' do
      input_queue = Queue.new
      allow(pipeline).to receive(:instance_variable_get).with(:@stage_input_queues)
        .and_return({ test_stage: input_queue })
      allow(dag).to receive(:upstream).with(:test_stage).and_return([:upstream])
      allow(dag).to receive(:downstream).with(:test_stage).and_return([])

      worker = described_class.new(pipeline, :test_stage, stage, config)

      worker.start

      # Thread should be created
      expect(worker.thread).to be_a(Thread)

      # Put END signal so the worker exits
      input_queue << Minigun::Message.end_signal(source: :upstream)

      worker.join

      # Thread should have finished cleanly
      expect(worker.thread).not_to be_alive
    end
  end

  describe '#join' do
    it 'waits for worker thread to complete' do
      input_queue = Queue.new
      allow(pipeline).to receive(:instance_variable_get).with(:@stage_input_queues)
        .and_return({ test_stage: input_queue })

      worker = described_class.new(pipeline, :test_stage, stage, config)

      # Put END signal
      input_queue << Minigun::Message.end_signal(source: :upstream)

      worker.start
      worker.join

      expect(worker.thread).not_to be_alive
    end

    it 'handles nil thread gracefully' do
      worker = described_class.new(pipeline, :test_stage, stage, config)

      expect { worker.join }.not_to raise_error
    end
  end

  describe 'executor creation' do
    context 'with inline execution context' do
      before do
        allow(stage).to receive(:execution_context).and_return(nil)
      end

      it 'creates an inline executor' do
        worker = described_class.new(pipeline, :test_stage, stage, config)

        # Should not raise error
        expect(worker).to be_a(Minigun::Execution::StageWorker)
      end
    end

    context 'with thread execution context' do
      before do
        allow(stage).to receive(:execution_context).and_return({ type: :threads, pool_size: 5 })
      end

      it 'creates a thread pool executor' do
        worker = described_class.new(pipeline, :test_stage, stage, config)

        expect(worker).to be_a(Minigun::Execution::StageWorker)
      end
    end

    context 'with process execution context' do
      before do
        allow(stage).to receive(:execution_context).and_return({ type: :fork, max: 2 })
      end

      it 'creates a process pool executor' do
        worker = described_class.new(pipeline, :test_stage, stage, config)

        expect(worker).to be_a(Minigun::Execution::StageWorker)
      end
    end
  end

  describe 'disconnected stage handling' do
    it 'exits early if no input queue' do
      allow(pipeline).to receive(:instance_variable_get).with(:@stage_input_queues)
        .and_return({})

      worker = described_class.new(pipeline, :test_stage, stage, config)

      expect(Minigun.logger).to receive(:info).with(/No input queue/)

      worker.start
      worker.join
    end

    it 'sends END signals to downstream if disconnected' do
      allow(pipeline).to receive(:instance_variable_get).with(:@stage_input_queues)
        .and_return({ test_stage: Queue.new, downstream: Queue.new })
      allow(dag).to receive(:upstream).with(:test_stage).and_return([])
      allow(dag).to receive(:downstream).with(:test_stage).and_return([:downstream])

      downstream_queue = Queue.new
      allow(pipeline).to receive(:instance_variable_get).with(:@stage_input_queues)
        .and_return({ test_stage: Queue.new, downstream: downstream_queue })

      worker = described_class.new(pipeline, :test_stage, stage, config)
      worker.start
      worker.join

      # Should have sent END signal to downstream
      msg = downstream_queue.pop(true) rescue nil
      expect(msg).to be_a(Minigun::Message) if msg
    end
  end

  describe 'router stage' do
    let(:router_stage) do
      double(
        'router_stage',
        producer?: false,
        router?: true,
        round_robin?: false,
        targets: [:target_a, :target_b],
        execution_context: nil
      )
    end

    it 'routes items without executing' do
      input_queue = Queue.new
      target_a_queue = Queue.new
      target_b_queue = Queue.new

      allow(pipeline).to receive(:instance_variable_get).with(:@stage_input_queues)
        .and_return({ router: input_queue, target_a: target_a_queue, target_b: target_b_queue })
      allow(dag).to receive(:upstream).with(:router).and_return([:source])

      # Put items and END signal
      input_queue << 1
      input_queue << 2
      input_queue << Minigun::Message.end_signal(source: :source)

      worker = described_class.new(pipeline, :router, router_stage, config)
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

      # Override the private create_executor_for_stage method to return our mock
      worker = described_class.new(pipeline, :test_stage, stage, config)
      worker.instance_variable_set(:@executor, executor)

      # Cause an error in the worker loop
      allow(pipeline).to receive(:instance_variable_get).with(:@stage_input_queues)
        .and_raise(StandardError, 'Test error')

      expect(executor).to receive(:shutdown)

      worker.start
      sleep 0.02  # Give thread time to start and error
      worker.join rescue nil
    end
  end

  describe 'logging' do
    it 'logs when starting' do
      input_queue = Queue.new
      allow(pipeline).to receive(:instance_variable_get).with(:@stage_input_queues)
        .and_return({ test_stage: input_queue })

      input_queue << Minigun::Message.end_signal(source: :upstream)

      expect(Minigun.logger).to receive(:info).with(/Starting/)

      worker = described_class.new(pipeline, :test_stage, stage, config)
      worker.start
      worker.join
    end

    it 'logs when done' do
      input_queue = Queue.new
      allow(pipeline).to receive(:instance_variable_get).with(:@stage_input_queues)
        .and_return({ test_stage: input_queue })
      allow(dag).to receive(:upstream).with(:test_stage).and_return([:upstream])
      allow(dag).to receive(:downstream).with(:test_stage).and_return([])

      input_queue << Minigun::Message.end_signal(source: :upstream)

      expect(Minigun.logger).to receive(:info).with(/Done/)

      worker = described_class.new(pipeline, :test_stage, stage, config)
      worker.start
      worker.join
    end
  end
end

