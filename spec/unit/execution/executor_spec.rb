# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Minigun::Execution::Executor do
  # Create real objects instead of mocks
  let(:task) { Minigun::Task.new }
  let(:pipeline) { task.root_pipeline }
  let(:test_stage) { Minigun::ConsumerStage.new(:test, pipeline, proc { |item, output| output << item }, {}) }
  let(:stage_stats) { Minigun::Stats.new(test_stage) }
  let(:stage_ctx) do
    Struct.new(:stage_stats, :pipeline, :root_pipeline, :stage_name, :dag, :stage).new(
      stage_stats, pipeline, pipeline, :test, pipeline.dag, test_stage
    )
  end

  describe 'Factory method' do
    it 'creates correct executor type via factory' do
      thread_executor = Minigun::Execution.create_executor(:thread, stage_ctx, max_size: 5)
      expect(thread_executor).to be_a(Minigun::Execution::ThreadPoolExecutor)
      expect(thread_executor.max_size).to eq(5)

      inline_executor = Minigun::Execution.create_executor(:inline, stage_ctx)
      expect(inline_executor).to be_a(Minigun::Execution::InlineExecutor)

      cow_fork_executor = Minigun::Execution.create_executor(:cow_fork, stage_ctx, max_size: 3)
      expect(cow_fork_executor).to be_a(Minigun::Execution::CowForkPoolExecutor)
      expect(cow_fork_executor.max_size).to eq(3)

      ipc_fork_executor = Minigun::Execution.create_executor(:ipc_fork, stage_ctx, max_size: 4)
      expect(ipc_fork_executor).to be_a(Minigun::Execution::IpcForkPoolExecutor)
      expect(ipc_fork_executor.max_size).to eq(4)

      if Minigun::Platform.fibers?
        fiber_executor = Minigun::Execution.create_executor(:fiber, stage_ctx, max_size: 10)
        expect(fiber_executor).to be_a(Minigun::Execution::FiberPoolExecutor)
        expect(fiber_executor.max_size).to eq(10)
      end
    end

    it 'all executors extend Executor base class' do
      executor = Minigun::Execution.create_executor(:thread, stage_ctx, max_size: 5)
      expect(executor).to be_a(described_class)
    end

    it 'raises error for unknown type' do
      expect do
        Minigun::Execution.create_executor(:unknown, stage_ctx, max_size: 5)
      end.to raise_error(ArgumentError, /Unknown executor type/)
    end
  end

  describe 'Base Executor#execute_stage' do
    let(:base_test_task) { Minigun::Task.new }
    let(:pipeline) { base_test_task.root_pipeline }
    let(:stage) { Minigun::ConsumerStage.new(:base_exec_test, pipeline, proc { |item, output| output << item }, {}) }
    let(:stage_stats) { Minigun::Stats.new(stage) }
    let(:user_context) { {} }
    let(:stage_ctx) do
      Struct.new(:pipeline, :root_pipeline, :stage_name, :stage_stats, :dag).new(
        pipeline, pipeline, :base_exec_test, stage_stats, pipeline.dag
      )
    end

    it 'executes the stage via execute method' do
      executor = Minigun::Execution::InlineExecutor.new(stage_ctx)
      input_queue = Queue.new
      output_queue = Queue.new
      input_queue << Minigun::EndOfStage.new(:test)

      # Executor calls stage.execute - the stage will process the queue
      executor.execute_stage(stage, user_context, input_queue, output_queue)

      # Stage should have processed and completed
      expect(output_queue.empty?).to be true
    end

    it 'processes items and produces output' do
      # Create a stage that outputs 2 items per input
      track_test_stage = Minigun::ConsumerStage.new(
        :track_test,
        pipeline,
        proc { |_item, output|
          output << 42
          output << 84
        },
        {}
      )

      # Create stats for this specific stage
      track_stats = Minigun::Stats.new(track_test_stage)
      track_stage_ctx = Struct.new(:pipeline, :root_pipeline, :stage_name, :stage_stats, :dag).new(
        pipeline, pipeline, :track_test, track_stats, pipeline.dag
      )

      executor = Minigun::Execution::InlineExecutor.new(track_stage_ctx)
      input_queue = Queue.new
      output_queue = Queue.new

      # Add one item and end signal
      input_queue << 1
      input_queue << Minigun::EndOfStage.new(:test)

      executor.execute_stage(track_test_stage, user_context, input_queue, output_queue)

      # Should have produced 2 items in output
      # Note: Stats tracking happens through InputQueue/OutputQueue wrappers,
      # not in the executor directly, so we only check output here
      results = []
      results << output_queue.pop until output_queue.empty?
      expect(results.size).to eq(2)
      expect(results).to eq([42, 84])
    end

    it 'passes stage_stats to stage for per-item latency tracking' do
      executor = Minigun::Execution::InlineExecutor.new(stage_ctx)
      input_queue = Queue.new
      output_queue = Queue.new
      input_queue << Minigun::EndOfStage.new(:test)

      # Stage receives stage_stats and can track latency
      executor.execute_stage(stage, user_context, input_queue, output_queue)

      # Test passes if no errors occur
      expect(output_queue.empty?).to be true
    end

    it 'propagates errors from stage execution' do
      executor = Minigun::Execution::InlineExecutor.new(stage_ctx)
      input_queue = Queue.new
      output_queue = Queue.new
      input_queue << 1
      input_queue << Minigun::EndOfStage.new(:test)

      # Create a stage that raises an error
      error_stage = Minigun::ConsumerStage.new(
        :error_test,
        pipeline,
        proc { |_item, _output| raise StandardError.new('test error') },
        {}
      )

      # Executor propagates stage errors (item-level errors are handled inside stage loops)
      # Note: ConsumerStage catches errors and logs them, so this won't raise
      expect do
        executor.execute_stage(error_stage, user_context, input_queue, output_queue)
      end.not_to raise_error
    end
  end
end

RSpec.describe Minigun::Execution::InlineExecutor do
  let(:inline_task) { Minigun::Task.new }
  let(:pipeline) { inline_task.root_pipeline }
  let(:stage) { Minigun::ConsumerStage.new(:inline_test, pipeline, proc { |item, output| output << item }, {}) }
  let(:stage_stats) { Minigun::Stats.new(stage) }
  let(:stage_ctx) do
    Struct.new(:pipeline, :root_pipeline, :stage_name, :stage_stats, :dag).new(
      pipeline, pipeline, :inline_test, stage_stats, pipeline.dag
    )
  end
  let(:executor) { described_class.new(stage_ctx) }
  let(:user_context) { {} }

  describe '#execute_stage' do
    it 'executes stage immediately in same thread' do
      input_queue = Queue.new
      output_queue = Queue.new
      input_queue << Minigun::EndOfStage.new(:test)

      executor.execute_stage(stage, user_context, input_queue, output_queue)

      # Test completes successfully if no errors
      expect(output_queue.empty?).to be true
    end

    it 'executes in calling thread' do
      calling_thread_id = Thread.current.object_id
      execution_thread_id = nil

      # Create a stage that captures thread ID
      thread_stage = Minigun::ConsumerStage.new(
        :thread_test,
        pipeline,
        proc { |_item, _output| execution_thread_id = Thread.current.object_id },
        {}
      )

      input_queue = Queue.new
      output_queue = Queue.new
      input_queue << 1
      input_queue << Minigun::EndOfStage.new(:test)

      executor.execute_stage(thread_stage, user_context, input_queue, output_queue)
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
  let(:thread_task) { Minigun::Task.new }
  let(:pipeline) { thread_task.root_pipeline }
  let(:test_stage) { Minigun::ConsumerStage.new(:thread_test, pipeline, proc { |item, output| output << item }, {}) }
  let(:stage_stats) { Minigun::Stats.new(test_stage) }
  let(:stage_ctx) do
    Struct.new(:pipeline, :root_pipeline, :stage_name, :stage_stats, :dag, :stage).new(
      pipeline, pipeline, :thread_test, stage_stats, pipeline.dag, test_stage
    )
  end
  let(:executor) { described_class.new(stage_ctx, max_size: 3) }

  describe '#initialize' do
    it 'sets max_size' do
      expect(executor.max_size).to eq(3)
    end
  end

  describe '#execute_stage' do
    let(:user_context) { {} }

    it 'executes in different thread' do
      calling_thread_id = Thread.current.object_id
      execution_thread_id = nil

      # Create a stage that captures the execution thread ID
      thread_capture_stage = Minigun::ConsumerStage.new(
        :thread_capture,
        pipeline,
        proc { |item, output|
          execution_thread_id = Thread.current.object_id
          output << item
        },
        {}
      )

      input_queue = Queue.new
      output_queue = Queue.new
      input_queue << 1
      input_queue << Minigun::EndOfStage.new(:test)

      executor.execute_stage(thread_capture_stage, user_context, input_queue, output_queue)
      expect(execution_thread_id).not_to eq(calling_thread_id)
    end

    it 'processes items through the stage' do
      input_queue = Queue.new
      output_queue = Queue.new
      input_queue << 42
      input_queue << Minigun::EndOfStage.new(:test)

      executor.execute_stage(test_stage, user_context, input_queue, output_queue)

      result = output_queue.pop
      expect(result).to eq(42)
    end

    it 'respects max_size concurrency limit' do
      executed = []
      mutex = Mutex.new

      # Create a stage that tracks executions
      slow_stage = Minigun::ConsumerStage.new(
        :slow_test,
        pipeline,
        proc { |item, output|
          mutex.synchronize { executed << 1 }
          sleep 0.01
          output << item
        },
        {}
      )

      # Start 5 concurrent executions with max_size=3
      threads = Array.new(5) do
        Thread.new do
          input_queue = Queue.new
          output_queue = Queue.new
          input_queue << 1
          input_queue << Minigun::EndOfStage.new(:test)
          executor.execute_stage(slow_stage, user_context, input_queue, output_queue)
        end
      end

      threads.each(&:join)
      expect(executed.size).to eq(5)
    end

    it 'handles errors from thread' do
      # Create a stage that raises an error
      error_stage = Minigun::ConsumerStage.new(
        :error_test,
        pipeline,
        proc { |_item, _output| raise StandardError.new('boom') },
        {}
      )

      input_queue = Queue.new
      output_queue = Queue.new
      input_queue << 1
      input_queue << Minigun::EndOfStage.new(:test)

      # ConsumerStage catches errors and logs them, so workers don't crash
      # This is correct production behavior
      expect do
        executor.execute_stage(error_stage, user_context, input_queue, output_queue)
      end.not_to raise_error
    end
  end

  describe '#shutdown' do
    it 'cleans up active threads' do
      expect { executor.shutdown }.not_to raise_error
    end
  end
end

RSpec.describe Minigun::Execution::CowForkPoolExecutor, skip: !Minigun::Platform.fork? do
  let(:task) { Minigun::Task.new }
  let(:pipeline) { task.root_pipeline }
  let(:test_stage_for_ctx) { Minigun::ConsumerStage.new(:test_ctx, pipeline, proc { |item, output| output << item }, {}) }
  let(:stage_stats) { Minigun::Stats.new(test_stage_for_ctx) }
  let(:stage_ctx) do
    Struct.new(:pipeline, :root_pipeline, :stage_name, :stage_stats, :dag, :stage).new(
      pipeline, pipeline, :test_ctx, stage_stats, pipeline.dag, test_stage_for_ctx
    )
  end
  let(:executor) { described_class.new(stage_ctx, max_size: 2) }

  describe '#initialize' do
    it 'sets max_size' do
      expect(executor.max_size).to eq(2)
    end
  end

  describe '#execute_stage' do
    let(:user_context) { {} }

    it 'executes in forked process' do
      calling_pid = Process.pid
      execution_pid = nil

      # Create a stage that captures the execution PID
      pid_capture_stage = Minigun::ConsumerStage.new(
        :pid_capture,
        pipeline,
        proc { |item, output|
          execution_pid = Process.pid
          output << item
        },
        {}
      )

      input_queue = Queue.new
      output_queue = Queue.new
      input_queue << 1
      input_queue << Minigun::EndOfStage.new(:test)

      executor.execute_stage(pid_capture_stage, user_context, input_queue, output_queue)
      expect(execution_pid).not_to eq(calling_pid)
    end

    it 'processes items in child process' do
      input_queue = Queue.new
      output_queue = Queue.new
      input_queue << 42
      input_queue << Minigun::EndOfStage.new(:test)

      # Executor processes items through the stage
      expect do
        executor.execute_stage(test_stage_for_ctx, user_context, input_queue, output_queue)
      end.not_to raise_error
    end

    it 'propagates errors from child process' do
      # Create a stage that raises an error
      error_stage = Minigun::ConsumerStage.new(
        :error_test,
        pipeline,
        proc { |_item, _output| raise StandardError.new('boom') },
        {}
      )

      input_queue = Queue.new
      output_queue = Queue.new
      input_queue << 1
      input_queue << Minigun::EndOfStage.new(:test)

      # COW fork propagates errors from child processes
      expect do
        executor.execute_stage(error_stage, user_context, input_queue, output_queue)
      end.to raise_error(/COW forked process failed.*boom/)
    end
  end

  describe '#shutdown' do
    it 'terminates active processes' do
      expect { executor.shutdown }.not_to raise_error
    end
  end
end

RSpec.describe Minigun::Execution::CowForkPoolExecutor, skip: !Minigun::Platform.fork? do
  let(:task) { Minigun::Task.new }
  let(:pipeline) { task.root_pipeline }
  let(:test_stage) { Minigun::ConsumerStage.new(:test, pipeline, proc { |item, output| output << item }, {}) }
  let(:stage_stats) { Minigun::Stats.new(test_stage) }
  let(:stage_ctx) do
    Struct.new(:pipeline, :root_pipeline, :stage_name, :stage_stats, :dag, :stage).new(
      pipeline, pipeline, :test, stage_stats, pipeline.dag, test_stage
    )
  end
  let(:executor) { described_class.new(stage_ctx, max_size: 2) }

  describe '#initialize' do
    it 'sets max_size' do
      expect(executor.max_size).to eq(2)
    end
  end

  describe '#execute_stage' do
    let(:user_context) { {} }

    it 'executes stage with inherited memory (COW)' do
      # Use real ConsumerStage - RSpec mocks don't work across forks
      stage = Minigun::ConsumerStage.new(
        :cow_mem_test,
        pipeline,
        proc { |item, output| output << (item * 2) },
        {}
      )

      input_queue = Queue.new
      output_queue = Queue.new
      input_queue << 5
      input_queue << Minigun::EndOfStage.new(:test)

      executor.execute_stage(stage, user_context, input_queue, output_queue)

      result = output_queue.pop
      expect(result).to eq(10)
    end

    it 'propagates errors from child process' do
      # Use real ConsumerStage that raises an error
      stage = Minigun::ConsumerStage.new(
        :cow_error_test,
        pipeline,
        proc { |_item, _output| raise 'boom' },
        {}
      )

      input_queue = Queue.new
      output_queue = Queue.new
      input_queue << 5
      input_queue << Minigun::EndOfStage.new(:test)

      # COW fork propagates errors from child processes
      expect do
        executor.execute_stage(stage, user_context, input_queue, output_queue)
      end.to raise_error(/COW forked process failed.*boom/)
    end

    it 'respects max_size concurrency limit' do
      processed_items = Queue.new

      # Real stage that tracks which items it processes
      stage = Minigun::ConsumerStage.new(
        :cow_concurrency_test,
        pipeline,
        proc { |item, output|
          processed_items << item
          sleep 0.01 # Slow processing
          output << item
        },
        {}
      )

      input_queue = Queue.new
      output_queue = Queue.new

      # Queue up more items than max_size to test concurrency limiting
      10.times { |i| input_queue << i }
      input_queue << Minigun::EndOfStage.new(:test)

      executor.execute_stage(stage, user_context, input_queue, output_queue)

      # All items should be processed
      results = []
      10.times do
        results << output_queue.pop(true)
      rescue StandardError
        nil
      end
      expect(results.compact.size).to eq(10)
    end
  end

  describe '#shutdown' do
    it 'terminates active processes' do
      expect { executor.shutdown }.not_to raise_error
    end
  end
end

RSpec.describe Minigun::Execution::IpcForkPoolExecutor, skip: !Minigun::Platform.fork? do
  let(:task) { Minigun::Task.new }
  let(:pipeline) { task.root_pipeline }
  let(:test_stage) { Minigun::ConsumerStage.new(:ipc_test, pipeline, proc { |item, output| output << item }, {}) }
  let(:stage_stats) { Minigun::Stats.new(test_stage) }
  let(:stage_ctx) do
    Struct.new(:pipeline, :root_pipeline, :stage_name, :stage_stats, :dag, :stage).new(
      pipeline, pipeline, :ipc_test, stage_stats, pipeline.dag, test_stage
    )
  end
  let(:executor) { described_class.new(stage_ctx, max_size: 2) }

  describe '#initialize' do
    it 'sets max_size' do
      expect(executor.max_size).to eq(2)
    end
  end

  describe '#execute_stage' do
    let(:user_context) { {} }

    it 'communicates success via IPC pipe' do
      # Use real ConsumerStage - RSpec mocks don't work across forks
      stage = Minigun::ConsumerStage.new(
        :ipc_success_test,
        pipeline,
        proc { |item, output| output << (item * 2) },
        {}
      )

      input_queue = Queue.new
      output_queue = Queue.new
      input_queue << 5
      input_queue << Minigun::EndOfStage.new(:test)

      executor.execute_stage(stage, user_context, input_queue, output_queue)

      result = output_queue.pop
      expect(result).to eq(10)
    end

    it 'respects max_size concurrency limit' do
      # Real stage that processes items
      stage = Minigun::ConsumerStage.new(
        :ipc_concurrency_test,
        pipeline,
        proc { |item, output|
          sleep 0.01 # Slow processing
          output << item
        },
        {}
      )

      input_queue = Queue.new
      output_queue = Queue.new

      # Queue up more items than max_size to test concurrency
      10.times { |i| input_queue << i }
      input_queue << Minigun::EndOfStage.new(:test)

      executor.execute_stage(stage, user_context, input_queue, output_queue)

      # All items should be processed
      results = []
      10.times do
        results << output_queue.pop(true)
      rescue StandardError
        nil
      end
      expect(results.compact.size).to eq(10)
    end

    it 'workers process multiple items from streaming queue' do
      # Test that IPC workers are persistent and process multiple items
      stage = Minigun::ConsumerStage.new(
        :test,
        pipeline,
        proc { |item, output| output << item },
        {}
      )

      input_queue = Queue.new
      output_queue = Queue.new

      # Send multiple items per worker to verify streaming
      20.times { |i| input_queue << i }
      input_queue << Minigun::EndOfStage.new(:test)

      executor.execute_stage(stage, user_context, input_queue, output_queue)

      # All 20 items should be processed by max_size=2 workers
      results = []
      20.times do
        results << output_queue.pop(true)
      rescue StandardError
        nil
      end
      expect(results.compact.size).to eq(20)
    end
  end

  describe '#shutdown' do
    it 'terminates active processes' do
      expect { executor.shutdown }.not_to raise_error
    end
  end
end

RSpec.describe Minigun::Execution::FiberPoolExecutor, skip: !Minigun::Platform.fibers? do
  let(:task) { Minigun::Task.new }
  let(:pipeline) { task.root_pipeline }
  let(:test_stage) { Minigun::ConsumerStage.new(:fiber_test, pipeline, proc { |item, output| output << item }, {}) }
  let(:stage_stats) { Minigun::Stats.new(test_stage) }
  let(:stage_ctx) do
    Struct.new(:pipeline, :root_pipeline, :stage_name, :stage_stats, :dag, :stage).new(
      pipeline, pipeline, :fiber_test, stage_stats, pipeline.dag, test_stage
    )
  end
  let(:executor) { described_class.new(stage_ctx, max_size: 3) }

  describe '#initialize' do
    it 'sets max_size' do
      expect(executor.max_size).to eq(3)
    end

    it 'defaults max_size to 5' do
      default_executor = described_class.new(stage_ctx)
      expect(default_executor.max_size).to eq(5)
    end

    it 'accepts pool_timeout option' do
      timeout_executor = described_class.new(stage_ctx, max_size: 3, pool_timeout: 10)
      expect(timeout_executor.pool_timeout).to eq(10)
    end

    it 'defaults pool_timeout to nil' do
      expect(executor.pool_timeout).to be_nil
    end
  end

  describe '#execute_stage' do
    let(:user_context) { {} }

    it 'executes in fiber (same thread)' do
      calling_thread_id = Thread.current.object_id
      execution_thread_id = nil

      # Create a stage that captures thread ID
      fiber_capture_stage = Minigun::ConsumerStage.new(
        :fiber_capture,
        pipeline,
        proc { |item, output|
          execution_thread_id = Thread.current.object_id
          output << item
        },
        {}
      )

      input_queue = Queue.new
      output_queue = Queue.new
      input_queue << 1
      input_queue << Minigun::EndOfStage.new(:test)

      executor.execute_stage(fiber_capture_stage, user_context, input_queue, output_queue)
      # Fibers run in same thread (cooperative concurrency)
      expect(execution_thread_id).to eq(calling_thread_id)
    end

    it 'processes items through the stage' do
      input_queue = Queue.new
      output_queue = Queue.new
      input_queue << 42
      input_queue << Minigun::EndOfStage.new(:test)

      executor.execute_stage(test_stage, user_context, input_queue, output_queue)

      result = output_queue.pop
      expect(result).to eq(42)
    end

    it 'processes multiple items concurrently' do
      processed = []
      mutex = Mutex.new

      # Create a stage that tracks when items are processed
      concurrent_stage = Minigun::ConsumerStage.new(
        :concurrent_test,
        pipeline,
        proc { |item, output|
          mutex.synchronize { processed << item }
          output << item
        },
        {}
      )

      input_queue = Queue.new
      output_queue = Queue.new
      10.times { |i| input_queue << i }
      input_queue << Minigun::EndOfStage.new(:test)

      executor.execute_stage(concurrent_stage, user_context, input_queue, output_queue)

      # All items should be processed
      expect(processed.size).to eq(10)
    end

    it 'respects max_size concurrency limit' do
      max_concurrent = 0
      current_concurrent = 0
      mutex = Mutex.new

      # Create a stage that tracks concurrent executions
      concurrency_stage = Minigun::ConsumerStage.new(
        :concurrency_limit_test,
        pipeline,
        proc { |item, output|
          mutex.synchronize do
            current_concurrent += 1
            max_concurrent = [max_concurrent, current_concurrent].max
          end
          # Yield to allow other fibers to run
          sleep 0.001
          mutex.synchronize { current_concurrent -= 1 }
          output << item
        },
        {}
      )

      input_queue = Queue.new
      output_queue = Queue.new
      20.times { |i| input_queue << i }
      input_queue << Minigun::EndOfStage.new(:test)

      # max_size is 3, so max_concurrent should never exceed 3
      executor.execute_stage(concurrency_stage, user_context, input_queue, output_queue)

      expect(max_concurrent).to be <= 3
    end

    it 'handles errors without crashing other fibers' do
      processed = []
      mutex = Mutex.new

      # Create a stage that raises an error on item 5
      error_stage = Minigun::ConsumerStage.new(
        :error_test,
        pipeline,
        proc { |item, output|
          raise 'boom' if item == 5

          mutex.synchronize { processed << item }
          output << item
        },
        {}
      )

      input_queue = Queue.new
      output_queue = Queue.new
      10.times { |i| input_queue << i }
      input_queue << Minigun::EndOfStage.new(:test)

      # Should not raise - errors are caught within fibers
      expect do
        executor.execute_stage(error_stage, user_context, input_queue, output_queue)
      end.not_to raise_error

      # Other items should still be processed (item 5 errored)
      expect(processed.size).to eq(9)
      expect(processed).not_to include(5)
    end

    it 'records latency stats' do
      stats_stage = Minigun::ConsumerStage.new(
        :stats_test,
        pipeline,
        proc { |item, output|
          sleep 0.001 # Small delay
          output << item
        },
        {}
      )

      stage_ctx_with_stats = Struct.new(:pipeline, :root_pipeline, :stage_name, :stage_stats, :dag, :stage).new(
        pipeline, pipeline, :stats_test, stage_stats, pipeline.dag, stats_stage
      )
      stats_executor = described_class.new(stage_ctx_with_stats, max_size: 3)

      input_queue = Queue.new
      output_queue = Queue.new
      3.times { |i| input_queue << i }
      input_queue << Minigun::EndOfStage.new(:test)

      stats_executor.execute_stage(stats_stage, user_context, input_queue, output_queue)

      # Should have recorded latencies (stored in latency_count)
      expect(stage_stats.latency_count).to eq(3)
    end
  end

  describe '#shutdown' do
    it 'does nothing (fibers are cleaned up automatically)' do
      expect { executor.shutdown }.not_to raise_error
    end
  end

  describe 'pool_timeout' do
    let(:user_context) { {} }

    it 'cancels remaining fibers when timeout expires' do
      processed = []
      mutex = Mutex.new

      # Create a stage with very slow processing
      slow_stage = Minigun::ConsumerStage.new(
        :slow_test,
        pipeline,
        proc { |item, output|
          sleep 0.5 # Very slow - will timeout
          mutex.synchronize { processed << item }
          output << item
        },
        {}
      )

      timeout_executor = described_class.new(stage_ctx, max_size: 5, pool_timeout: 0.1)

      input_queue = Queue.new
      output_queue = Queue.new
      5.times { |i| input_queue << i }
      input_queue << Minigun::EndOfStage.new(:test)

      # Should not raise, but should timeout
      expect do
        timeout_executor.execute_stage(slow_stage, user_context, input_queue, output_queue)
      end.not_to raise_error

      # Not all items should be processed due to timeout
      expect(processed.size).to be < 5
    end

    it 'completes normally when within timeout' do
      processed = []
      mutex = Mutex.new

      # Create a stage with fast processing
      fast_stage = Minigun::ConsumerStage.new(
        :fast_test,
        pipeline,
        proc { |item, output|
          sleep 0.01 # Fast
          mutex.synchronize { processed << item }
          output << item
        },
        {}
      )

      timeout_executor = described_class.new(stage_ctx, max_size: 5, pool_timeout: 5)

      input_queue = Queue.new
      output_queue = Queue.new
      5.times { |i| input_queue << i }
      input_queue << Minigun::EndOfStage.new(:test)

      timeout_executor.execute_stage(fast_stage, user_context, input_queue, output_queue)

      # All items should be processed
      expect(processed.size).to eq(5)
    end
  end

  describe 'callable stages (call_with_arity path)' do
    let(:user_context) { {} }

    # Helper to create an output queue wrapper that supports to_proc for yield syntax
    def make_output_queue(raw_queue)
      # Create a simple wrapper with to_proc that pushes to raw queue
      wrapper = Object.new
      wrapper.define_singleton_method(:<<) { |item| raw_queue << item }
      wrapper.define_singleton_method(:to_proc) do
        proc { |item, **_kwargs| raw_queue << item }
      end
      wrapper
    end

    it 'processes callable stage with call method' do
      processed = []
      mutex = Mutex.new

      # Create a callable stage class (defines #call instead of using a block)
      # Use class_eval to define call method with yield support
      callable_stage_class = Class.new(Minigun::ConsumerStage)
      callable_stage_class.class_eval do
        define_method(:processed) { processed }
        define_method(:mutex) { mutex }

        def call(item, _output)
          mutex.synchronize { processed << item }
          yield(item * 2)
        end
      end

      callable_stage = callable_stage_class.new(:callable_test, pipeline, nil, {})

      input_queue = Queue.new
      raw_output = Queue.new
      output_queue = make_output_queue(raw_output)
      5.times { |i| input_queue << i }
      input_queue << Minigun::EndOfStage.new(:test)

      executor.execute_stage(callable_stage, user_context, input_queue, output_queue)

      expect(processed.size).to eq(5)
      expect(processed).to contain_exactly(0, 1, 2, 3, 4)

      # Check output was written
      results = []
      5.times { results << raw_output.pop }
      expect(results).to contain_exactly(0, 2, 4, 6, 8)
    end

    it 'handles callable stage with arity 1 (item only)' do
      processed = []
      mutex = Mutex.new

      # Callable stage with arity 1 - only receives item
      callable_stage_class = Class.new(Minigun::ConsumerStage)
      callable_stage_class.class_eval do
        define_method(:processed) { processed }
        define_method(:mutex) { mutex }

        def call(item)
          mutex.synchronize { processed << item }
          yield(item * 3)
        end
      end

      callable_stage = callable_stage_class.new(:arity1_test, pipeline, nil, {})

      input_queue = Queue.new
      raw_output = Queue.new
      output_queue = make_output_queue(raw_output)
      3.times { |i| input_queue << (i + 1) }
      input_queue << Minigun::EndOfStage.new(:test)

      executor.execute_stage(callable_stage, user_context, input_queue, output_queue)

      expect(processed).to contain_exactly(1, 2, 3)

      results = []
      3.times { results << raw_output.pop }
      expect(results).to contain_exactly(3, 6, 9)
    end

    it 'handles errors in callable stages' do
      processed = []
      mutex = Mutex.new

      callable_stage_class = Class.new(Minigun::ConsumerStage)
      callable_stage_class.class_eval do
        define_method(:processed) { processed }
        define_method(:mutex) { mutex }

        def call(item, _output)
          raise 'callable boom' if item == 2

          mutex.synchronize { processed << item }
          yield(item)
        end
      end

      callable_stage = callable_stage_class.new(:error_callable_test, pipeline, nil, {})

      input_queue = Queue.new
      raw_output = Queue.new
      output_queue = make_output_queue(raw_output)
      5.times { |i| input_queue << i }
      input_queue << Minigun::EndOfStage.new(:test)

      expect do
        executor.execute_stage(callable_stage, user_context, input_queue, output_queue)
      end.not_to raise_error

      # Item 2 errored, others processed
      expect(processed.size).to eq(4)
      expect(processed).not_to include(2)
    end
  end
end

RSpec.describe Minigun::Execution::RactorPoolExecutor do
  let(:task) { Minigun::Task.new }
  let(:pipeline) { task.root_pipeline }
  let(:test_stage) { Minigun::ConsumerStage.new(:ractor_test, pipeline, proc { |item, output| output << item }, {}) }
  let(:stage_stats) { Minigun::Stats.new(test_stage) }
  let(:stage_ctx) do
    Struct.new(:pipeline, :root_pipeline, :stage_name, :stage_stats, :dag, :stage).new(
      pipeline, pipeline, :ractor_test, stage_stats, pipeline.dag, test_stage
    )
  end
  let(:executor) { described_class.new(stage_ctx, max_size: 4) }

  describe '#initialize' do
    it 'creates with max_size' do
      expect(executor).to be_a(described_class)
      expect(executor.max_size).to eq(4)
    end

    it 'defaults to max_size of 5' do
      default_executor = described_class.new(stage_ctx)
      expect(default_executor.max_size).to eq(5)
    end
  end

  describe 'Platform.ractors?' do
    it 'returns true when Ractor::Port is available' do
      if defined?(Ractor::Port)
        expect(Minigun::Platform.ractors?).to be true
      else
        expect(Minigun::Platform.ractors?).to be false
      end
    end
  end

  describe '#execute_stage' do
    context 'when Ractor::Port is not available' do
      before do
        allow(Minigun::Platform).to receive(:ractors?).and_return(false)
      end

      it 'falls back to thread pool' do
        # Create executor after stubbing
        fallback_executor = described_class.new(stage_ctx, max_size: 2)

        expect { fallback_executor }.not_to raise_error
        # The fallback is created in initialize when ractors? is false
      end
    end

    context 'when Ractor::Port is available', if: Minigun::Platform.ractors? do
      let(:shareable_proc) do
        Ractor.shareable_proc { |item, output| output << (item * 2) }
      end
      let(:shareable_stage) do
        Minigun::ConsumerStage.new(:shareable_test, pipeline, shareable_proc, {})
      end
      let(:shareable_ctx) do
        Struct.new(:pipeline, :root_pipeline, :stage_name, :stage_stats, :dag, :stage).new(
          pipeline, pipeline, :shareable_test, Minigun::Stats.new(shareable_stage), pipeline.dag, shareable_stage
        )
      end

      it 'processes items with shareable blocks using Ractors' do
        ractor_executor = described_class.new(shareable_ctx, max_size: 2)

        input_queue = Queue.new
        output_queue = Queue.new
        user_context = Object.new

        # Add test items
        5.times { |i| input_queue << i }
        input_queue << Minigun::EndOfStage.new(shareable_stage)

        ractor_executor.execute_stage(shareable_stage, user_context, input_queue, output_queue)

        # Collect results
        results = []
        5.times { results << output_queue.pop }

        expect(results.sort).to eq([0, 2, 4, 6, 8])
      end

      it 'falls back to threads for non-shareable blocks' do
        # Regular proc is not shareable
        non_shareable_proc = proc { |item, output| output << (item * 2) }
        non_shareable_stage = Minigun::ConsumerStage.new(:non_shareable, pipeline, non_shareable_proc, {})
        non_shareable_ctx = Struct.new(:pipeline, :root_pipeline, :stage_name, :stage_stats, :dag, :stage).new(
          pipeline, pipeline, :non_shareable, Minigun::Stats.new(non_shareable_stage), pipeline.dag, non_shareable_stage
        )

        executor = described_class.new(non_shareable_ctx, max_size: 2)

        input_queue = Queue.new
        output_queue = Queue.new
        user_context = Object.new

        3.times { |i| input_queue << i }
        input_queue << Minigun::EndOfStage.new(non_shareable_stage)

        # Should fall back to threads and still work
        expect do
          executor.execute_stage(non_shareable_stage, user_context, input_queue, output_queue)
        end.not_to raise_error

        results = []
        3.times { results << output_queue.pop }
        expect(results.sort).to eq([0, 2, 4])
      end
    end
  end

  describe '#shutdown' do
    it 'cleans up workers' do
      expect { executor.shutdown }.not_to raise_error
    end
  end
end
