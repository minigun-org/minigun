# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Stage-Specific Hooks' do
  before do
    allow(Minigun.logger).to receive(:info)
  end

  describe 'Option 2: Named hooks' do
    let(:pipeline_class) do
      Class.new do
        include Minigun::DSL

        attr_accessor :events

        def initialize
          @events = []
        end

        pipeline do
          producer :generate do
            @events << :producer_run
            emit(1)
            emit(2)
          end

          before :generate do
            @events << :before_generate
          end

          after :generate do
            @events << :after_generate
          end

          processor :transform do |num|
            @events << :processor_run
            emit(num * 2)
          end

          before :transform do
            @events << :before_transform
          end

          after :transform do
            @events << :after_transform
          end

          consumer :collect do |num|
            @events << :consumer_run
          end
        end
      end
    end

    it 'executes before and after hooks for each stage' do
      task = pipeline_class.new
      task.run

      expect(task.events).to include(:before_generate, :producer_run, :after_generate)
      expect(task.events).to include(:before_transform, :processor_run, :after_transform)

      # Check ordering: before should come before run, run before after
      generate_idx = task.events.index(:producer_run)
      expect(task.events[generate_idx - 1]).to eq(:before_generate)
      expect(task.events[generate_idx + 1]).to eq(:after_generate)
    end
  end

  describe 'Option 3: Inline proc hooks' do
    let(:pipeline_class) do
      Class.new do
        include Minigun::DSL

        attr_accessor :events

        def initialize
          @events = []
        end

        pipeline do
          producer :generate,
                   before: -> { @events << :before_inline },
                   after: -> { @events << :after_inline } do
            @events << :producer_run
            emit(1)
          end

          consumer :collect do |num|
            @events << :collected
          end
        end
      end
    end

    it 'executes inline before and after hooks' do
      task = pipeline_class.new
      task.run

      expect(task.events).to include(:before_inline, :producer_run, :after_inline)

      # Check ordering
      run_idx = task.events.index(:producer_run)
      expect(task.events[run_idx - 1]).to eq(:before_inline)
      expect(task.events[run_idx + 1]).to eq(:after_inline)
    end
  end

  describe 'Fork-specific hooks' do
    let(:pipeline_class) do
      Class.new do
        include Minigun::DSL

        attr_accessor :events

        def initialize
          @events = []
          @mutex = Mutex.new
        end

        pipeline do
          producer :generate do
            3.times { |i| emit(i) }
          end

          accumulator :batch

          process_per_batch(max: 1) do
            consumer :process do |num|
              @mutex.synchronize { @events << :process_run }
            end
          end

          before_fork :process do
            @events << :before_fork_process
          end

          after_fork :process do
            @events << :after_fork_process
          end
        end
      end
    end

    it 'executes stage-specific fork hooks' do
      task = pipeline_class.new
      task.run

      # Fork hooks should be present if forking occurred
      if Process.respond_to?(:fork)
        expect(task.events).to include(:before_fork_process)
        # after_fork happens in child process, won't be in @events
      end
    end
  end

  describe 'Mixed pipeline and stage hooks' do
    let(:pipeline_class) do
      Class.new do
        include Minigun::DSL

        attr_accessor :events

        def initialize
          @events = []
        end

        pipeline do
          before_run do
            @events << :before_run_pipeline
          end

          after_run do
            @events << :after_run_pipeline
          end

          producer :generate do
            @events << :producer_run
            emit(1)
          end

          before :generate do
            @events << :before_generate_stage
          end

          after :generate do
            @events << :after_generate_stage
          end

          consumer :collect do |num|
            @events << :collect_run
          end
        end
      end
    end

    it 'executes both pipeline-level and stage-level hooks in correct order' do
      task = pipeline_class.new
      task.run

      # Pipeline hooks bookend everything
      expect(task.events.first).to eq(:before_run_pipeline)
      expect(task.events.last).to eq(:after_run_pipeline)

      # Stage hooks surround their stage execution
      expect(task.events).to include(:before_generate_stage, :producer_run, :after_generate_stage)
    end
  end

  describe 'Multiple hooks on same stage' do
    let(:pipeline_class) do
      Class.new do
        include Minigun::DSL

        attr_accessor :events

        def initialize
          @events = []
        end

        pipeline do
          producer :generate do
            @events << :producer_run
            emit(1)
          end

          before :generate do
            @events << :before_1
          end

          before :generate do
            @events << :before_2
          end

          after :generate do
            @events << :after_1
          end

          after :generate do
            @events << :after_2
          end

          consumer :collect do |num|
          end
        end
      end
    end

    it 'executes all hooks for a stage in order they were defined' do
      task = pipeline_class.new
      task.run

      # All before hooks should run before the stage
      prod_idx = task.events.index(:producer_run)
      expect(task.events[prod_idx - 2]).to eq(:before_1)
      expect(task.events[prod_idx - 1]).to eq(:before_2)

      # All after hooks should run after the stage
      expect(task.events[prod_idx + 1]).to eq(:after_1)
      expect(task.events[prod_idx + 2]).to eq(:after_2)
    end
  end
end

