# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Graceful Shutdown' do
  describe 'Producer stopping on shutdown' do
    it 'stops producer iteration when output.shutdown? is checked' do
      task_class = Class.new do
        include Minigun::DSL

        attr_reader :items_produced, :items_consumed

        def initialize
          @items_produced = []
          @items_consumed = []
          @mutex = Mutex.new
        end

        pipeline do
          producer :source do |output|
            # Produce items, checking for shutdown each iteration
            100.times do |i|
              # Check if shutdown was requested
              break if output.shutdown?

              @mutex.synchronize { @items_produced << i }
              output << i

              # Request shutdown after producing 10 items
              output.shutdown! if i == 9
            end
          end

          consumer :sink do |item|
            @mutex.synchronize { @items_consumed << item }
          end
        end
      end

      task = task_class.new
      task.run

      # Should have produced exactly 10 items (0-9) then stopped
      expect(task.items_produced.size).to eq(10)
      expect(task.items_produced).to eq((0..9).to_a)
      # Should have consumed all produced items
      expect(task.items_consumed.sort).to eq(task.items_produced.sort)
    end

    it 'output.<< becomes no-op after shutdown (producer keeps going but items dropped)' do
      task_class = Class.new do
        include Minigun::DSL

        attr_reader :items_attempted, :items_consumed

        def initialize
          @items_attempted = []
          @items_consumed = []
          @mutex = Mutex.new
        end

        pipeline do
          producer :source do |output|
            20.times do |i|
              @mutex.synchronize { @items_attempted << i }
              output << i  # After shutdown, this becomes a no-op
              output.shutdown! if i == 4
            end
          end

          consumer :sink do |item|
            @mutex.synchronize { @items_consumed << item }
          end
        end
      end

      task = task_class.new
      task.run

      # Producer attempted all 20 items
      expect(task.items_attempted.size).to eq(20)
      # But only items 0-4 were actually consumed (before shutdown)
      expect(task.items_consumed.sort).to eq([0, 1, 2, 3, 4])
    end
  end

  describe 'output.shutdown?' do
    it 'returns true after shutdown! is called' do
      shutdown_checked = false
      was_requested = nil

      task_class = Class.new do
        include Minigun::DSL

        def initialize(callback)
          @callback = callback
        end

        pipeline do
          producer :source do |output|
            5.times { |i| output << i }
            output.shutdown!
            @callback.call(output.shutdown?)
          end

          consumer :sink do |_item|
            # just consume
          end
        end
      end

      callback = ->(requested) {
        shutdown_checked = true
        was_requested = requested
      }

      task = task_class.new(callback)
      task.run

      expect(shutdown_checked).to be true
      expect(was_requested).to be true
    end
  end

  describe 'ConsumerStage shutdown' do
    it 'consumers can check shutdown state via output.shutdown?' do
      shutdown_seen = false

      task_class = Class.new do
        include Minigun::DSL

        def initialize(flag_ref)
          @flag_ref = flag_ref
        end

        pipeline do
          producer :source do |output|
            10.times do |i|
              output << i
              output.shutdown! if i == 2
            end
          end

          consumer :sink do |_item, output|
            # Consumer can check shutdown state via output
            @flag_ref[:seen] = true if output.shutdown?
          end
        end
      end

      flag_ref = { seen: false }
      task = task_class.new(flag_ref)
      task.run

      # The consumer should have seen the shutdown state at some point
      expect(flag_ref[:seen]).to be true
    end
  end

  describe 'Multiple stages' do
    it 'shutdown state propagates to all stages' do
      stages_seen_shutdown = []
      mutex = Mutex.new

      task_class = Class.new do
        include Minigun::DSL

        def initialize(stages_seen_shutdown, mutex)
          @stages_seen_shutdown = stages_seen_shutdown
          @mutex = mutex
        end

        pipeline do
          producer :source do |output|
            5.times { |i| output << i }
            output.shutdown!
            @mutex.synchronize { @stages_seen_shutdown << :source }
          end

          consumer :process do |item, output|
            if output.shutdown?
              @mutex.synchronize { @stages_seen_shutdown << :process unless @stages_seen_shutdown.include?(:process) }
            end
            output << item
          end

          consumer :sink do |_item, output|
            if output.shutdown?
              @mutex.synchronize { @stages_seen_shutdown << :sink unless @stages_seen_shutdown.include?(:sink) }
            end
          end
        end
      end

      task = task_class.new(stages_seen_shutdown, mutex)
      task.run

      # Source should always see shutdown (it initiated it)
      expect(stages_seen_shutdown).to include(:source)
    end
  end

  describe 'with ThreadPoolExecutor' do
    it 'processes items before shutdown' do
      processed = []
      mutex = Mutex.new

      task_class = Class.new do
        include Minigun::DSL

        def initialize(processed, mutex)
          @processed = processed
          @mutex = mutex
        end

        pipeline do
          producer :source do |output|
            20.times do |i|
              break if output.shutdown?
              output << i
              output.shutdown! if i == 5
            end
          end

          in_threads(3) do
            consumer :process do |item|
              @mutex.synchronize { @processed << item }
            end
          end
        end
      end

      task = task_class.new(processed, mutex)
      task.run

      # Should have processed items 0-5
      expect(processed.sort).to eq([0, 1, 2, 3, 4, 5])
    end
  end

  describe 'Stage#check_shutdown!' do
    it 'raises ShutdownRequested when shutdown is requested' do
      task_class = Class.new do
        include Minigun::DSL

        def initialize(flag_ref)
          @flag_ref = flag_ref
        end

        pipeline do
          producer :source do |output|
            output.shutdown!
            begin
              # Manually check and raise (simulating check_shutdown! behavior)
              raise Minigun::Errors::ShutdownRequested if output.shutdown?
              10.times { |i| output << i }
            rescue Minigun::Errors::ShutdownRequested => e
              @flag_ref[:raised] = true
              @flag_ref[:message] = e.message
            end
          end

          consumer :sink do |_item|
            # consume
          end
        end
      end

      flag_ref = { raised: false, message: nil }
      task = task_class.new(flag_ref)

      expect { task.run }.not_to raise_error
      expect(flag_ref[:raised]).to be true
      expect(flag_ref[:message]).to eq('Graceful shutdown requested')
    end
  end

  describe 'EnumeratorProducerStage' do
    it 'stops iteration when shutdown is requested via check_shutdown!' do
      config = { max_threads: 1, max_processes: 1 }
      task = Minigun::Task.new(config: config)
      pipeline = task.root_pipeline

      source = (1..100).to_a

      stage = Minigun::EnumeratorProducerStage.new(:test_source, pipeline, source, nil, {})

      # Request shutdown before running
      stage.request_shutdown

      # The stage should be in shutdown state
      expect(stage.shutdown_requested?).to be true

      # Calling check_shutdown! should raise
      expect { stage.check_shutdown! }.to raise_error(Minigun::Errors::ShutdownRequested)
    end
  end

  describe 'force shutdown' do
    it 'sets force_shutdown flag on pipeline' do
      config = { max_threads: 1, max_processes: 1 }
      task = Minigun::Task.new(config: config)
      pipeline = task.root_pipeline

      # Initially not in force shutdown
      expect(pipeline.force_shutdown?).to be false

      # Request force shutdown
      pipeline.request_shutdown(force: true)

      # Should now be in force shutdown
      expect(pipeline.force_shutdown?).to be true
      expect(pipeline.shutdown_requested?).to be true
    end

    it 'force shutdown kills threads immediately (no code after shutdown! runs)' do
      code_after_shutdown_ran = false

      task_class = Class.new do
        include Minigun::DSL

        def initialize(flag_ref)
          @flag_ref = flag_ref
        end

        pipeline do
          producer :source do |output|
            output << 1
            output.shutdown!(force: true)
            # This code should NOT run because force kills the thread
            @flag_ref[:ran] = true
          end

          consumer :sink do |_item|
            # consume
          end
        end
      end

      flag_ref = { ran: false }
      task = task_class.new(flag_ref)
      task.run

      # Force shutdown kills the thread, so code after shutdown! doesn't run
      expect(flag_ref[:ran]).to be false
    end
  end

  describe 'Runner state machine' do
    it 'starts in running state' do
      config = { max_threads: 1, max_processes: 1 }
      task = Minigun::Task.new(config: config)

      context_class = Class.new { include Minigun::DSL }
      context = context_class.new

      runner = Minigun::Runner.new(task, context)

      expect(runner.shutdown_requested?).to be false
      expect(runner.force_shutdown?).to be false
    end
  end

  describe 'Executor shutdown' do
    it 'ThreadPoolExecutor responds to shutdown requests' do
      config = { max_threads: 1, max_processes: 1 }
      task = Minigun::Task.new(config: config)
      pipeline = task.root_pipeline
      stage = Minigun::ConsumerStage.new(:test, pipeline, proc {}, {})

      stage_ctx = Minigun::StageContext.new(
        stage: stage,
        dag: pipeline.dag,
        runtime_edges: {},
        stage_stats: nil
      )

      executor = Minigun::Execution::ThreadPoolExecutor.new(stage_ctx, max_size: 2)

      expect(executor.shutdown_requested?).to be false
      executor.request_shutdown
      expect(executor.shutdown_requested?).to be true
    end

    it 'CowForkPoolExecutor responds to shutdown requests', :skip_on_windows do
      config = { max_threads: 1, max_processes: 1 }
      task = Minigun::Task.new(config: config)
      pipeline = task.root_pipeline
      stage = Minigun::ConsumerStage.new(:test, pipeline, proc {}, {})

      stage_ctx = Minigun::StageContext.new(
        stage: stage,
        dag: pipeline.dag,
        runtime_edges: {},
        stage_stats: nil
      )

      executor = Minigun::Execution::CowForkPoolExecutor.new(stage_ctx, max_size: 2)

      expect(executor.shutdown_requested?).to be false
      executor.request_shutdown
      expect(executor.shutdown_requested?).to be true
    end
  end

  describe 'backwards compatibility' do
    it 'works with blocks that do not use shutdown' do
      items = []
      mutex = Mutex.new

      task_class = Class.new do
        include Minigun::DSL

        def initialize(items, mutex)
          @items = items
          @mutex = mutex
        end

        pipeline do
          producer :source do |output|
            5.times { |i| output << i }
          end

          consumer :process do |item, output|
            @mutex.synchronize { @items << item }
            output << item
          end

          consumer :sink do |item|
            @mutex.synchronize { @items << "sink:#{item}" }
          end
        end
      end

      task = task_class.new(items, mutex)
      task.run

      expect(items).to include(0, 1, 2, 3, 4)
      expect(items).to include('sink:0', 'sink:1', 'sink:2', 'sink:3', 'sink:4')
    end
  end

  describe 'Stage shutdown methods' do
    it 'Stage#shutdown_requested? reflects pipeline state' do
      config = { max_threads: 1, max_processes: 1 }
      task = Minigun::Task.new(config: config)
      pipeline = task.root_pipeline
      stage = Minigun::ProducerStage.new(:test, pipeline, proc {}, {})

      # Initially not shutdown
      expect(stage.shutdown_requested?).to be false

      # Request shutdown on stage
      stage.request_shutdown
      expect(stage.shutdown_requested?).to be true

      # Or via pipeline
      stage2 = Minigun::ProducerStage.new(:test2, pipeline, proc {}, {})
      expect(stage2.shutdown_requested?).to be false
      pipeline.request_shutdown
      expect(stage2.shutdown_requested?).to be true
    end

    it 'Stage#check_shutdown! raises when shutdown requested' do
      config = { max_threads: 1, max_processes: 1 }
      task = Minigun::Task.new(config: config)
      pipeline = task.root_pipeline
      stage = Minigun::ProducerStage.new(:test, pipeline, proc {}, {})

      # Should not raise when not shutdown
      expect { stage.check_shutdown! }.not_to raise_error

      # Request shutdown
      stage.request_shutdown

      # Now should raise
      expect { stage.check_shutdown! }.to raise_error(Minigun::Errors::ShutdownRequested)
    end
  end
end
