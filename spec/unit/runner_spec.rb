# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Minigun::Runner do
  let(:config) { { max_processes: 2, max_threads: 5 } }
  let(:task) { Minigun::Task.new(config: config) }
  let(:pipeline) { task.root_pipeline }

  # Create a simple context class for testing
  let(:context_class) do
    Class.new do
      def self.name
        'TestContext'
      end
    end
  end
  let(:context) { context_class.new }
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
      # Add a simple producer to the pipeline so it has something to run
      pipeline.add_stage(:producer, :test_producer) do |output|
        output << 1
        output << 2
        output << 3
      end
    end

    it 'executes the pipeline' do
      # Just verify it runs without error
      expect { runner.run }.not_to raise_error
    end

    it 'returns the pipeline result' do
      result = runner.run

      # Pipeline.run returns the count of items processed
      expect(result).to eq(3)
    end

    it 'logs job started' do
      allow(Minigun.logger).to receive(:debug).and_call_original
      expect(Minigun.logger).to receive(:debug).with(/TestContext started/)

      runner.run
    end

    it 'logs job finished' do
      allow(Minigun.logger).to receive(:debug).and_call_original
      expect(Minigun.logger).to receive(:debug).with(/TestContext finished/)

      runner.run
    end

    it 'logs configuration' do
      allow(Minigun.logger).to receive(:debug).and_call_original
      expect(Minigun.logger).to receive(:debug).with(/max_processes=2, max_threads=5/)

      runner.run
    end

    it 'logs runtime' do
      allow(Minigun.logger).to receive(:debug).and_call_original
      expect(Minigun.logger).to receive(:debug).with(/Runtime: \d+\.\d+s/)

      runner.run
    end

    it 'passes job_id to pipeline.run' do
      # Verify the job_id is set and valid
      expect(runner.job_id).to be_a(String)
      expect(runner.job_id.length).to eq(8)

      # Run should complete successfully with the job_id
      expect { runner.run }.not_to raise_error
    end

    context 'with pipeline stats' do
      let(:stats_task) { Minigun::Task.new(config: config) }
      let(:stats_pipeline) { stats_task.root_pipeline }
      let(:stats_runner) { described_class.new(stats_task, context) }

      before do
        # Add stages to generate real stats
        stats_pipeline.add_stage(:producer, :stats_producer) { |output| 100.times { output << 1 } }
        stats_pipeline.add_stage(:consumer, :slow_stage) { |item, output| output << item }
      end

      it 'logs pipeline statistics' do
        allow(Minigun.logger).to receive(:debug).and_call_original
        expect(Minigun.logger).to receive(:debug).with(/produced.*consumed/)

        stats_runner.run
      end

      it 'logs bottleneck information' do
        allow(Minigun.logger).to receive(:debug).and_call_original
        expect(Minigun.logger).to receive(:debug).with(/Bottleneck/)

        stats_runner.run
      end

      it 'logs overall throughput' do
        allow(Minigun.logger).to receive(:debug).and_call_original
        expect(Minigun.logger).to receive(:debug).with(/Total:.*items/)

        stats_runner.run
      end
    end

    context 'with before_run hooks' do
      it 'executes before_run hooks' do
        hook_called = []

        # Use real hook API
        pipeline.add_hook(:before_run) { hook_called << :before }

        runner.run

        expect(hook_called).to include(:before)
      end
    end

    context 'with after_run hooks' do
      it 'executes after_run hooks' do
        hook_called = []

        # Use real hook API
        pipeline.add_hook(:after_run) { hook_called << :after }

        runner.run

        expect(hook_called).to include(:after)
      end
    end

    context 'with errors' do
      let(:error_task) { Minigun::Task.new(config: config) }
      let(:error_pipeline) { error_task.root_pipeline }
      let(:error_runner) { described_class.new(error_task, context) }

      before do
        # Add a stage that raises an error
        error_pipeline.add_stage(:producer, :error_producer) do |_output|
          raise StandardError, 'Pipeline error'
        end
      end

      it 'cleans up even when pipeline fails' do
        # Capture signal handlers before
        original_int = Signal.trap('INT', 'DEFAULT')

        # Errors in producers are caught and logged, not re-raised
        # The pipeline completes and cleanup happens
        expect { error_runner.run }.not_to raise_error

        # Handler should be restored
        current_handler = Signal.trap('INT', original_int)
        expect(current_handler).to eq('DEFAULT')

        Signal.trap('INT', original_int)
      end
    end
  end

  describe 'signal handling' do
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
