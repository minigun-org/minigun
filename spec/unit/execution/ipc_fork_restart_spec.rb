# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Minigun::Execution::WorkerMonitor do
  describe '#initialize' do
    it 'accepts valid restart policies' do
      %i[never transient permanent].each do |policy|
        expect do
          described_class.new(restart_policy: policy)
        end.not_to raise_error
      end
    end

    it 'rejects invalid restart policies' do
      expect do
        described_class.new(restart_policy: :invalid)
      end.to raise_error(Minigun::Errors::InvalidOption, /Invalid restart_policy/)
    end

    it 'converts string policies to symbols' do
      monitor = described_class.new(restart_policy: 'transient')
      expect(monitor.restart_policy).to eq(:transient)
    end

    it 'sets default values' do
      monitor = described_class.new
      expect(monitor.restart_policy).to eq(:never)
      expect(monitor.max_restarts).to eq(3)
      expect(monitor.restart_window).to eq(60)
    end
  end

  describe '#enabled?' do
    it 'returns false for :never policy' do
      monitor = described_class.new(restart_policy: :never)
      expect(monitor.enabled?).to be false
    end

    it 'returns true for :transient policy' do
      monitor = described_class.new(restart_policy: :transient)
      expect(monitor.enabled?).to be true
    end

    it 'returns true for :permanent policy' do
      monitor = described_class.new(restart_policy: :permanent)
      expect(monitor.enabled?).to be true
    end
  end

  describe '#should_restart?' do
    context 'with :never policy' do
      let(:monitor) { described_class.new(restart_policy: :never) }

      it 'never restarts' do
        status = double('process_status', signaled?: true, exitstatus: nil)
        expect(monitor.should_restart?(status)).to be false
      end
    end

    context 'with :transient policy' do
      let(:monitor) { described_class.new(restart_policy: :transient) }

      it 'restarts workers killed by signal' do
        status = double('process_status', signaled?: true, exitstatus: nil)
        expect(monitor.should_restart?(status)).to be true
      end

      it 'restarts workers with non-zero exit' do
        status = double('process_status', signaled?: false, exitstatus: 1)
        expect(monitor.should_restart?(status)).to be true
      end

      it 'does not restart workers with zero exit' do
        status = double('process_status', signaled?: false, exitstatus: 0)
        expect(monitor.should_restart?(status)).to be false
      end
    end

    context 'with :permanent policy' do
      let(:monitor) { described_class.new(restart_policy: :permanent) }

      it 'restarts workers killed by signal' do
        status = double('process_status', signaled?: true, exitstatus: nil)
        expect(monitor.should_restart?(status)).to be true
      end

      it 'restarts workers with non-zero exit' do
        status = double('process_status', signaled?: false, exitstatus: 1)
        expect(monitor.should_restart?(status)).to be true
      end

      it 'restarts workers with zero exit' do
        status = double('process_status', signaled?: false, exitstatus: 0)
        expect(monitor.should_restart?(status)).to be true
      end
    end
  end

  describe '#restart_allowed? and #record_restart' do
    let(:monitor) do
      described_class.new(
        restart_policy: :transient,
        max_restarts: 3,
        restart_window: 60
      )
    end

    it 'allows restarts within limit' do
      worker_index = 0

      # First 3 restarts should be allowed
      3.times do
        expect(monitor.restart_allowed?(worker_index)).to be true
        monitor.record_restart(worker_index)
      end

      # 4th restart should be denied
      expect(monitor.restart_allowed?(worker_index)).to be false
    end

    it 'tracks restarts per worker independently' do
      # Worker 0 exhausts restarts
      3.times { monitor.record_restart(0) }
      expect(monitor.restart_allowed?(0)).to be false

      # Worker 1 should still be allowed
      expect(monitor.restart_allowed?(1)).to be true
    end
  end

  describe '#restart_count' do
    let(:monitor) do
      described_class.new(
        restart_policy: :transient,
        max_restarts: 5,
        restart_window: 60
      )
    end

    it 'counts restarts for a worker' do
      expect(monitor.restart_count(0)).to eq(0)

      2.times { monitor.record_restart(0) }
      expect(monitor.restart_count(0)).to eq(2)

      3.times { monitor.record_restart(0) }
      expect(monitor.restart_count(0)).to eq(5)
    end

    it 'returns 0 for unknown worker' do
      expect(monitor.restart_count(99)).to eq(0)
    end
  end

  describe '#request_shutdown and #shutdown_requested?' do
    let(:monitor) { described_class.new(restart_policy: :transient) }

    it 'starts not shutdown' do
      expect(monitor.shutdown_requested?).to be false
    end

    it 'can be shutdown' do
      monitor.request_shutdown
      expect(monitor.shutdown_requested?).to be true
    end
  end

  describe '#format_exit_status' do
    let(:monitor) { described_class.new }

    it 'formats signal deaths' do
      status = double('process_status', signaled?: true, termsig: 9, exitstatus: nil)
      expect(monitor.format_exit_status(status)).to eq('signal 9')
    end

    it 'formats exit codes' do
      status = double('process_status', signaled?: false, exitstatus: 42)
      expect(monitor.format_exit_status(status)).to eq('exit code 42')
    end

    it 'handles unknown status' do
      status = double('process_status', signaled?: false, exitstatus: nil)
      expect(monitor.format_exit_status(status)).to eq('unknown')
    end
  end
end

RSpec.describe 'IPC Fork Worker Restart Integration' do
  let(:task) { Minigun::Task.new }
  let(:pipeline) { task.root_pipeline }

  let(:stage) do
    Minigun::ConsumerStage.new(:test_stage, pipeline, proc { |item, output| output << (item * 2) }, {})
  end

  let(:stage_stats) { Minigun::Stats.new(stage) }

  let(:stage_ctx) do
    Struct.new(:stage_stats, :pipeline, :root_pipeline, :stage).new(
      stage_stats, pipeline, pipeline, stage
    )
  end

  describe 'IpcForkPoolExecutor with restart policy' do
    it 'accepts restart policy options' do
      executor = Minigun::Execution::IpcForkPoolExecutor.new(
        stage_ctx,
        max_size: 2,
        restart_policy: :transient,
        max_restarts: 5,
        restart_window: 30
      )
      expect(executor).to be_a(Minigun::Execution::IpcForkPoolExecutor)
    end
  end

  describe 'end-to-end restart behavior', :slow do
    it 'completes processing even when workers crash' do
      # Create a stage that crashes on certain items
      crashing_proc = proc do |item, output|
        if item == 5
          # Simulate crash - exit with error
          exit!(1)
        end
        output << (item * 2)
      end
      crashing_stage = Minigun::ConsumerStage.new(:crashing_stage, pipeline, crashing_proc, {})
      crashing_stats = Minigun::Stats.new(crashing_stage)

      crashing_ctx = Struct.new(:stage_stats, :pipeline, :root_pipeline, :stage).new(
        crashing_stats, pipeline, pipeline, crashing_stage
      )

      executor = Minigun::Execution::IpcForkPoolExecutor.new(
        crashing_ctx,
        max_size: 2,
        restart_policy: :transient,
        max_restarts: 3
      )

      input_queue = Queue.new
      output_queue = Queue.new

      # Queue items (including the crashing one)
      (1..10).each { |i| input_queue << i }
      input_queue << Minigun::EndOfStage.new(crashing_stage)

      # Execute - should complete despite crash
      executor.execute_stage(crashing_stage, {}, input_queue, output_queue)

      results = []
      results << output_queue.pop until output_queue.empty?

      # We should get results for non-crashing items
      # When worker crashes, items in its queue may be lost
      # With restart, subsequent items should be processed
      # The key assertion: pipeline completes and produces results
      expect(results).not_to be_empty

      # At minimum, items processed before crash and after restart should appear
      # Can't guarantee all items due to round-robin distribution
      expect(results.size).to be >= 5 # At least half should succeed
      expect(results).to all(be_even) # All results should be doubled values
    end
  end
end
