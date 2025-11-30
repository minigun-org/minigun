# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'IPC Fork Worker Restart', skip: !Minigun::Platform.fork? do
  let(:task) { Minigun::Task.new }
  let(:pipeline) { task.root_pipeline }

  let(:stage) do
    Minigun::ConsumerStage.new(:test_stage, pipeline, proc { |item, output| output << item * 2 }, {})
  end

  let(:stage_stats) { Minigun::Stats.new(stage) }

  let(:stage_ctx) do
    Struct.new(:stage_stats, :pipeline, :root_pipeline, :stage).new(
      stage_stats, pipeline, pipeline, stage
    )
  end

  describe 'restart_policy validation' do
    it 'accepts valid restart policies' do
      %i[never transient permanent].each do |policy|
        expect {
          Minigun::Execution::IpcForkPoolExecutor.new(
            stage_ctx,
            max_size: 2,
            restart_policy: policy
          )
        }.not_to raise_error
      end
    end

    it 'rejects invalid restart policies' do
      expect {
        Minigun::Execution::IpcForkPoolExecutor.new(
          stage_ctx,
          max_size: 2,
          restart_policy: :invalid
        )
      }.to raise_error(ArgumentError, /Invalid restart_policy/)
    end

    it 'converts string policies to symbols' do
      executor = Minigun::Execution::IpcForkPoolExecutor.new(
        stage_ctx,
        max_size: 2,
        restart_policy: 'transient'
      )
      # Should not raise - string converted to symbol
      expect(executor).to be_a(Minigun::Execution::IpcForkPoolExecutor)
    end
  end

  describe 'restart policy :never (default)' do
    let(:executor) do
      Minigun::Execution::IpcForkPoolExecutor.new(
        stage_ctx,
        max_size: 2,
        restart_policy: :never
      )
    end

    it 'does not restart workers by default' do
      # With :never policy, worker deaths are not restarted
      # We can verify this by checking the should_restart_worker? method
      status = double('process_status', signaled?: true, exitstatus: nil)
      expect(executor.send(:should_restart_worker?, status)).to be false
    end
  end

  describe 'restart policy :transient' do
    let(:executor) do
      Minigun::Execution::IpcForkPoolExecutor.new(
        stage_ctx,
        max_size: 2,
        restart_policy: :transient
      )
    end

    it 'restarts workers killed by signal' do
      status = double('process_status', signaled?: true, exitstatus: nil)
      expect(executor.send(:should_restart_worker?, status)).to be true
    end

    it 'restarts workers with non-zero exit' do
      status = double('process_status', signaled?: false, exitstatus: 1)
      expect(executor.send(:should_restart_worker?, status)).to be true
    end

    it 'does not restart workers with zero exit' do
      status = double('process_status', signaled?: false, exitstatus: 0)
      expect(executor.send(:should_restart_worker?, status)).to be false
    end
  end

  describe 'restart policy :permanent' do
    let(:executor) do
      Minigun::Execution::IpcForkPoolExecutor.new(
        stage_ctx,
        max_size: 2,
        restart_policy: :permanent
      )
    end

    it 'restarts workers regardless of exit status' do
      # Killed by signal
      status1 = double('process_status', signaled?: true, exitstatus: nil)
      expect(executor.send(:should_restart_worker?, status1)).to be true

      # Non-zero exit
      status2 = double('process_status', signaled?: false, exitstatus: 1)
      expect(executor.send(:should_restart_worker?, status2)).to be true

      # Zero exit (normal)
      status3 = double('process_status', signaled?: false, exitstatus: 0)
      expect(executor.send(:should_restart_worker?, status3)).to be true
    end
  end

  describe 'restart rate limiting' do
    let(:executor) do
      Minigun::Execution::IpcForkPoolExecutor.new(
        stage_ctx,
        max_size: 2,
        restart_policy: :transient,
        max_restarts: 3,
        restart_window: 60
      )
    end

    it 'allows restarts within limit' do
      worker_index = 0

      # First 3 restarts should be allowed
      3.times do
        expect(executor.send(:restart_allowed?, worker_index)).to be true
        executor.send(:record_restart, worker_index)
      end

      # 4th restart should be denied
      expect(executor.send(:restart_allowed?, worker_index)).to be false
    end

    it 'allows restarts after window expires' do
      worker_index = 0

      # Record max restarts
      3.times { executor.send(:record_restart, worker_index) }
      expect(executor.send(:restart_allowed?, worker_index)).to be false

      # Simulate time passing by clearing old restarts
      executor.instance_variable_get(:@worker_restarts)[worker_index] = []

      # Should allow restarts again
      expect(executor.send(:restart_allowed?, worker_index)).to be true
    end

    it 'tracks restarts per worker independently' do
      # Worker 0 exhausts restarts
      3.times { executor.send(:record_restart, 0) }
      expect(executor.send(:restart_allowed?, 0)).to be false

      # Worker 1 should still be allowed
      expect(executor.send(:restart_allowed?, 1)).to be true
    end
  end

  describe 'format_exit_status helper' do
    let(:executor) do
      Minigun::Execution::IpcForkPoolExecutor.new(
        stage_ctx,
        max_size: 2,
        restart_policy: :transient
      )
    end

    it 'formats signal deaths' do
      status = double('process_status', signaled?: true, termsig: 9, exitstatus: nil)
      expect(executor.send(:format_exit_status, status)).to eq('signal 9')
    end

    it 'formats exit codes' do
      status = double('process_status', signaled?: false, exitstatus: 42)
      expect(executor.send(:format_exit_status, status)).to eq('exit code 42')
    end

    it 'handles unknown status' do
      status = double('process_status', signaled?: false, exitstatus: nil)
      expect(executor.send(:format_exit_status, status)).to eq('unknown')
    end
  end

  describe 'end-to-end restart behavior', :slow do
    # This test actually forks processes to verify restart behavior
    it 'completes processing even when workers crash' do
      # Create a stage that crashes on certain items
      crashing_proc = proc do |item, output|
        if item == 5
          # Simulate crash - exit with error
          exit!(1)
        end
        output << item * 2
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
      results.each { |r| expect(r).to be_even } # All results should be doubled values
    end
  end
end
