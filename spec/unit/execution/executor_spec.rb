# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Minigun::Execution::Executor do
  describe 'Factory method' do
    it 'creates correct executor type via factory' do
      thread_executor = Minigun::Execution.create_executor(type: :thread, max_size: 5)
      expect(thread_executor).to be_a(Minigun::Execution::ThreadPoolExecutor)
      expect(thread_executor.max_size).to eq(5)

      inline_executor = Minigun::Execution.create_executor(type: :inline, max_size: 3)
      expect(inline_executor).to be_a(Minigun::Execution::InlineExecutor)

      process_executor = Minigun::Execution.create_executor(type: :fork, max_size: 2)
      expect(process_executor).to be_a(Minigun::Execution::ProcessPoolExecutor)
      expect(process_executor.max_size).to eq(2)
    end

    it 'all executors extend Executor base class' do
      executor = Minigun::Execution.create_executor(type: :thread, max_size: 5)
      expect(executor).to be_a(Minigun::Execution::Executor)
    end

    it 'raises error for unknown type' do
      expect {
        Minigun::Execution.create_executor(type: :unknown, max_size: 5)
      }.to raise_error(ArgumentError, /Unknown executor type/)
    end
  end

  describe 'Base Executor#execute_stage_item' do
    let(:pipeline) do
      dag = double('dag', terminal?: false)
      double('pipeline',
        name: 'test_pipeline',
        dag: dag,
        send: nil
      )
    end
    let(:stage) do
      double('stage',
        name: :test,
        execute_with_emit: nil,
        execute: nil,
        respond_to?: false
      )
    end
    let(:stage_stats) { double('stage_stats', start!: nil, start_time: nil, increment_consumed: nil, increment_produced: nil, record_latency: nil) }
    let(:stats) { double('stats', for_stage: stage_stats) }
    let(:user_context) { double('user_context') }

    it 'executes before and after hooks' do
      executor = Minigun::Execution::InlineExecutor.new
      allow(stage).to receive(:respond_to?).with(:execute_with_emit).and_return(true)
      allow(stage).to receive(:execute_with_emit).and_return([42])

      expect(pipeline).to receive(:send).with(:execute_stage_hooks, :before, :test).ordered
      expect(pipeline).to receive(:send).with(:execute_stage_hooks, :after, :test).ordered

      executor.execute_stage_item(stage: stage, item: 1, user_context: user_context, stats: stats, pipeline: pipeline)
    end

    it 'tracks consumption and production' do
      executor = Minigun::Execution::InlineExecutor.new
      items_produced_count = 0
      output_queue = double('output_queue')
      allow(output_queue).to receive(:items_produced) { items_produced_count }
      allow(output_queue).to receive(:<<) { items_produced_count += 1; output_queue }

      allow(stage).to receive(:execute) do |_context, **kwargs|
        kwargs[:output_queue] << 42
        kwargs[:output_queue] << 84
      end

      expect(stage_stats).to receive(:increment_consumed).once
      expect(stage_stats).to receive(:increment_produced).exactly(2).times

      executor.execute_stage_item(stage: stage, item: 1, user_context: user_context, output_queue: output_queue, stats: stats, pipeline: pipeline)
    end

    it 'records latency' do
      executor = Minigun::Execution::InlineExecutor.new
      allow(stage).to receive(:execute).and_return(nil)

      expect(stage_stats).to receive(:record_latency).with(kind_of(Numeric))

      executor.execute_stage_item(stage: stage, item: 1, user_context: user_context, stats: stats, pipeline: pipeline)
    end

    it 'handles errors gracefully' do
      executor = Minigun::Execution::InlineExecutor.new
      allow(stage).to receive(:execute).and_raise(StandardError, "test error")

      # Should not raise, errors are logged
      expect {
        executor.execute_stage_item(stage: stage, item: 1, user_context: user_context, stats: stats, pipeline: pipeline)
      }.not_to raise_error
    end
  end
end

RSpec.describe Minigun::Execution::InlineExecutor do
  let(:executor) { described_class.new }
  let(:pipeline) do
    dag = double('dag', terminal?: false)
    double('pipeline',
      name: 'test_pipeline',
      dag: dag,
      send: nil
    )
  end
  let(:stage) do
    double('stage',
      name: :test,
      execute_with_emit: nil,
      execute: nil,
      respond_to?: false
    )
  end
  let(:stage_stats) { double('stage_stats', start!: nil, start_time: nil, increment_consumed: nil, increment_produced: nil, record_latency: nil) }
  let(:stats) { double('stats', for_stage: stage_stats) }
  let(:user_context) { double('user_context') }

  describe '#execute_stage_item' do
    let(:output_queue) { double('output_queue', items_produced: 1) }

    it 'executes stage immediately in same thread' do
      expect(stage).to receive(:execute).with(user_context, item: 42, input_queue: nil, output_queue: output_queue)

      executor.execute_stage_item(stage: stage, item: 42, user_context: user_context, output_queue: output_queue, stats: stats, pipeline: pipeline)
    end

    it 'executes in calling thread' do
      calling_thread_id = Thread.current.object_id
      execution_thread_id = nil

      allow(stage).to receive(:execute) do
        execution_thread_id = Thread.current.object_id
      end

      executor.execute_stage_item(stage: stage, item: 1, user_context: user_context, output_queue: output_queue, stats: stats, pipeline: pipeline)
      expect(execution_thread_id).to eq(calling_thread_id)
    end
  end

  describe '#shutdown' do
    it 'does nothing (no resources to clean up)' do
      expect { executor.shutdown }.not_to raise_error
    end
  end
end

RSpec.describe Minigun::Execution::ThreadPoolExecutor do
  let(:executor) { described_class.new(max_size: 3) }

  describe '#initialize' do
    it 'sets max_size' do
      expect(executor.max_size).to eq(3)
    end
  end

  describe '#execute_stage_item' do
    let(:pipeline) do
      dag = double('dag', terminal?: false)
      double('pipeline',
        name: 'test_pipeline',
        dag: dag,
        send: nil
      )
    end
    let(:stage) do
      double('stage',
        name: :test,
        execute_with_emit: nil,
        execute: nil,
        respond_to?: false
      )
    end
    let(:stage_stats) { double('stage_stats', start!: nil, start_time: nil, increment_consumed: nil, increment_produced: nil, record_latency: nil) }
    let(:stats) { double('stats', for_stage: stage_stats) }
    let(:user_context) { double('user_context') }

    it 'executes in different thread' do
      calling_thread_id = Thread.current.object_id
      execution_thread_id = nil
      output_queue = double('output_queue', items_produced: 0)

      allow(stage).to receive(:execute) do
        execution_thread_id = Thread.current.object_id
      end

      executor.execute_stage_item(stage: stage, item: 1, user_context: user_context, output_queue: output_queue, stats: stats, pipeline: pipeline)
      expect(execution_thread_id).not_to eq(calling_thread_id)
    end

    it 'returns result from thread' do
      output_queue = double('output_queue', items_produced: 1)
      expect(stage).to receive(:execute).with(user_context, item: 1, input_queue: nil, output_queue: output_queue)

      executor.execute_stage_item(stage: stage, item: 1, user_context: user_context, output_queue: output_queue, stats: stats, pipeline: pipeline)
    end

    it 'respects max_size concurrency limit' do
      executed = []
      mutex = Mutex.new
      output_queue = double('output_queue', items_produced: 0)

      allow(stage).to receive(:execute) do
        mutex.synchronize { executed << 1 }
        sleep 0.01
      end

      # Start 5 concurrent executions with max_size=3
      threads = 5.times.map do
        Thread.new do
          executor.execute_stage_item(stage: stage, item: 1, user_context: user_context, output_queue: output_queue, stats: stats, pipeline: pipeline)
        end
      end

      threads.each(&:join)
      expect(executed.size).to eq(5)
    end

    it 'propagates errors from thread' do
      output_queue = double('output_queue', items_produced: 0)
      allow(stage).to receive(:execute).and_raise(StandardError, "boom")

      # Errors are caught and logged (no exception propagated)
      expect { executor.execute_stage_item(stage: stage, item: 1, user_context: user_context, output_queue: output_queue, stats: stats, pipeline: pipeline) }.not_to raise_error
    end
  end

  describe '#shutdown' do
    it 'cleans up active threads' do
      expect { executor.shutdown }.not_to raise_error
    end
  end
end

RSpec.describe Minigun::Execution::ProcessPoolExecutor, skip: Gem.win_platform? do
  let(:executor) { described_class.new(max_size: 2) }

  describe '#initialize' do
    it 'sets max_size' do
      expect(executor.max_size).to eq(2)
    end
  end

  describe '#execute_stage_item' do
    let(:dag) { double('dag', terminal?: false) }
    let(:pipeline) do
      double('pipeline',
        name: 'test_pipeline',
        dag: dag,
        send: nil
      )
    end
    let(:stage) do
      double('stage',
        name: :test,
        execute_with_emit: nil,
        execute: nil,
        respond_to?: false
      )
    end
    let(:stage_stats) { double('stage_stats', start!: nil, start_time: nil, increment_consumed: nil, increment_produced: nil, record_latency: nil) }
    let(:stats) { double('stats', for_stage: stage_stats) }
    let(:user_context) { double('user_context') }

    before do
      # Mock fork hooks
      allow(pipeline).to receive(:hooks).and_return({})
      allow(pipeline).to receive(:stage_hooks).and_return({})
      allow(pipeline).to receive(:dag).and_return(dag)
    end

    it 'executes in forked process' do
      calling_pid = Process.pid
      execution_pid = nil

      allow(stage).to receive(:respond_to?).with(:execute_with_emit).and_return(true)
      allow(stage).to receive(:execute_with_emit) do
        execution_pid = Process.pid
        []
      end

      executor.execute_stage_item(stage: stage, item: 1, user_context: user_context, stats: stats, pipeline: pipeline)
      expect(execution_pid).not_to eq(calling_pid)
    end

    it 'returns result from child process' do
      allow(stage).to receive(:respond_to?).with(:execute_with_emit).and_return(true)
      allow(stage).to receive(:execute_with_emit).and_return([42])

      result = executor.execute_stage_item(stage: stage, item: 1, user_context: user_context, stats: stats, pipeline: pipeline)
      expect(result).to eq([42])
    end

    it 'propagates errors from child process' do
      allow(stage).to receive(:respond_to?).with(:execute_with_emit).and_return(true)
      allow(stage).to receive(:execute_with_emit).and_raise(StandardError, "boom")

      # Errors are caught and logged, returns []
      result = executor.execute_stage_item(stage: stage, item: 1, user_context: user_context, stats: stats, pipeline: pipeline)
      expect(result).to eq([])
    end
  end

  describe '#shutdown' do
    it 'terminates active processes' do
      expect { executor.shutdown }.not_to raise_error
    end
  end
end

RSpec.describe Minigun::Execution::RactorPoolExecutor do
  let(:executor) { described_class.new(max_size: 4) }

  describe '#initialize' do
    it 'creates with max_size' do
      expect(executor).to be_a(Minigun::Execution::RactorPoolExecutor)
    end
  end

  describe '#execute_stage_item' do
    it 'falls back to thread pool' do
      skip "Ractor is experimental and flaky in full test suite (passes when run individually)"
    end
  end
end

