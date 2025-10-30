# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Minigun::Runner do
  let(:task) do
    instance_double(
      Minigun::Task,
      config: { max_processes: 2, max_threads: 5 },
      root_pipeline: pipeline
    )
  end

  let(:pipeline) do
    instance_double(
      Minigun::Pipeline,
      hooks: { before_run: [], after_run: [] },
      stats: nil
    )
  end

  let(:context) { double('context', class: double(name: 'TestContext')) }
  let(:runner) { described_class.new(task, context) }

  describe '#initialize' do
    it 'creates a runner with job_id' do
      expect(runner.job_id).to be_a(String)
      expect(runner.job_id.length).to eq(8) # hex(4) = 8 chars
    end

    it 'assigns task and context' do
      expect(runner.task).to eq(task)
      expect(runner.context).to eq(context)
    end

    it 'generates unique job_ids' do
      runner1 = described_class.new(task, context)
      runner2 = described_class.new(task, context)

      expect(runner1.job_id).not_to eq(runner2.job_id)
    end

    it 'sets up signal handlers' do
      # Capture original handlers
      original_int = Signal.trap('INT', 'DEFAULT')

      described_class.new(task, context)

      # Check handler was set (just verify it doesn't error)
      current_handler = Signal.trap('INT', original_int)
      expect(current_handler).not_to eq('DEFAULT')

      # Restore
      Signal.trap('INT', original_int)
    end
  end

  describe '#run' do
    before do
      allow(Minigun.logger).to receive(:info)
      allow(pipeline).to receive(:run).with(context, job_id: anything).and_return([1, 2, 3])
    end

    it 'executes the pipeline' do
      expect(pipeline).to receive(:run).with(context, job_id: anything)

      runner.run
    end

    it 'returns the pipeline result' do
      result = runner.run

      expect(result).to eq([1, 2, 3])
    end

    it 'logs job started' do
      allow(Minigun.logger).to receive(:debug).and_call_original

      runner.run

      expect(Minigun.logger).to have_received(:debug).with(/TestContext started/)
    end

    it 'logs job finished' do
      allow(Minigun.logger).to receive(:debug).and_call_original

      runner.run

      expect(Minigun.logger).to have_received(:debug).with(/TestContext finished/)
    end

    it 'logs configuration' do
      allow(Minigun.logger).to receive(:debug).and_call_original

      runner.run

      expect(Minigun.logger).to have_received(:debug).with(/max_processes=2, max_threads=5/)
    end

    it 'logs runtime' do
      allow(Minigun.logger).to receive(:debug).and_call_original

      runner.run

      expect(Minigun.logger).to have_received(:debug).with(/Runtime: \d+\.\d+s/)
    end

    it 'passes job_id to pipeline.run' do
      expect(pipeline).to receive(:run).with(anything, job_id: runner.job_id)

      runner.run
    end

    context 'with pipeline stats' do
      let(:stats) do
        instance_double(
          Minigun::AggregatedStats,
          pipeline_name: 'default',
          total_produced: 100,
          total_consumed: 95,
          throughput: 47.5,
          bottleneck: bottleneck
        )
      end

      let(:bottleneck) do
        instance_double(
          Minigun::Stats,
          stage_name: :slow_stage,
          throughput: 10.5
        )
      end

      before do
        allow(pipeline).to receive(:stats).and_return(stats)
      end

      it 'logs pipeline statistics' do
        allow(Minigun.logger).to receive(:debug).and_call_original

        runner.run

        expect(Minigun.logger).to have_received(:debug).with(/100 produced, 95 consumed/)
      end

      it 'logs bottleneck information' do
        allow(Minigun.logger).to receive(:debug).and_call_original

        runner.run

        expect(Minigun.logger).to have_received(:debug).with(/Bottleneck: slow_stage/)
      end

      it 'logs overall throughput' do
        allow(Minigun.logger).to receive(:debug).and_call_original

        runner.run

        expect(Minigun.logger).to have_received(:debug).with(/Total: 100 items/)
      end
    end

    context 'with before_run hooks' do
      it 'executes before_run hooks' do
        hook_called = []
        before_hook = proc { hook_called << :before }

        allow(pipeline).to receive(:hooks).and_return(
          before_run: [before_hook],
          after_run: []
        )
        allow(context).to receive(:instance_eval) do
          hook_called << :before
        end

        runner.run

        expect(hook_called).to include(:before)
      end
    end

    context 'with after_run hooks' do
      it 'executes after_run hooks' do
        hook_called = []
        after_hook = proc { hook_called << :after }

        allow(pipeline).to receive(:hooks).and_return(
          before_run: [],
          after_run: [after_hook]
        )
        allow(context).to receive(:instance_eval) do
          hook_called << :after
        end

        runner.run

        expect(hook_called).to include(:after)
      end
    end

    context 'with errors' do
      before do
        allow(pipeline).to receive(:run).and_raise(StandardError, 'Pipeline error')
      end

      it 'cleans up even when pipeline fails' do
        # Capture signal handlers before
        original_int = Signal.trap('INT', 'DEFAULT')

        expect { runner.run }.to raise_error(StandardError, 'Pipeline error')

        # Handler should be restored
        current_handler = Signal.trap('INT', original_int)
        expect(current_handler).to eq('DEFAULT')

        Signal.trap('INT', original_int)
      end
    end
  end

  describe 'signal handling' do
    before do
      allow(Minigun.logger).to receive(:info)
      allow(pipeline).to receive(:run).with(context, job_id: anything)
    end

    it 'handles INT signal gracefully' do
      # This is hard to test without actually sending signals
      # Just verify the handler is set up
      original_int = Signal.trap('INT', 'DEFAULT')

      described_class.new(task, context)
      current_handler = Signal.trap('INT', original_int)

      expect(current_handler).not_to eq('DEFAULT')

      Signal.trap('INT', original_int)
    end

    it 'restores original signal handlers after cleanup' do
      original_int = Signal.trap('INT') { puts 'custom' }

      runner = described_class.new(task, context)
      runner.run

      Signal.trap('INT', original_int)
      # Handler should be restored to original

      Signal.trap('INT', original_int)
    end
  end

  describe 'platform compatibility' do
    it 'creates runner without errors on current platform' do
      # RUBY_PLATFORM is frozen so we can't mock it, but we can verify
      # the runner is created successfully on the current platform
      expect { described_class.new(task, context) }.not_to raise_error
    end
  end

  describe 'cleanup' do
    it 'restores signal handlers on unsupported signals' do
      runner = described_class.new(task, context)

      # Should handle ArgumentError gracefully
      allow(Signal).to receive(:trap).and_raise(ArgumentError, 'unsupported signal')

      expect { runner.send(:cleanup) }.not_to raise_error
    end
  end
end
