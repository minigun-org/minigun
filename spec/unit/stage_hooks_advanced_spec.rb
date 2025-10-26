# frozen_string_literal: true

require 'spec_helper'
require 'tempfile'

RSpec.describe 'Advanced Stage Hook Behaviors' do
  before do
    allow(Minigun.logger).to receive(:info)
  end

  describe 'hook execution order' do
    let(:complex_pipeline) do
      Class.new do
        include Minigun::DSL

        attr_accessor :execution_order

        def initialize
          @execution_order = []
          @temp_order_file = Tempfile.new(['minigun_order', '.txt'])
          @temp_order_file.close
        end

        def cleanup
          File.unlink(@temp_order_file.path) if @temp_order_file && File.exist?(@temp_order_file.path)
        end

        pipeline do
          before_run { @execution_order << '1_pipeline_before_run' }

          producer :gen do
            @execution_order << '4_producer_block'
            emit(1)
          end

          before(:gen) { @execution_order << '3_producer_before' }
          after(:gen) { @execution_order << '5_producer_after' }

          processor :proc do |item|
            @execution_order << '7_processor_block'
            emit(item * 2)
          end

          before(:proc) { @execution_order << '6_processor_before' }
          after(:proc) { @execution_order << '8_processor_after' }

          before_fork { @execution_order << '9_pipeline_before_fork' }

          # Use process_per_batch so forking actually happens
          process_per_batch(max: 1) do
            consumer :cons do |item|
              # Write to temp file (fork-safe)
              File.open(@temp_order_file.path, 'a') do |f|
                f.flock(File::LOCK_EX)
                f.puts('12_consumer_block')
                f.flock(File::LOCK_UN)
              end
            end

            before_fork(:cons) { @execution_order << '10_consumer_before_fork' }
            after_fork(:cons) do
              # Write to temp file (child process can't mutate parent's @execution_order)
              File.open(@temp_order_file.path, 'a') do |f|
                f.flock(File::LOCK_EX)
                f.puts('11_consumer_after_fork')
                f.flock(File::LOCK_UN)
              end
            end
          end

          after_fork do
            # Write to temp file (child process can't mutate parent's @execution_order)
            File.open(@temp_order_file.path, 'a') do |f|
              f.flock(File::LOCK_EX)
              f.puts('13_pipeline_after_fork')
              f.flock(File::LOCK_UN)
            end
          end
          
          after_run do
            # Read fork events from temp file
            if File.exist?(@temp_order_file.path)
              fork_events = File.readlines(@temp_order_file.path).map(&:strip)
              @execution_order.concat(fork_events)
            end
            @execution_order << '2_pipeline_after_run'
          end
        end
      end
    end

    it 'executes hooks in correct order' do
      pipeline = complex_pipeline.new
      
      begin
        pipeline.run

        order = pipeline.execution_order

        # Pipeline before_run comes first
        expect(order.first).to eq('1_pipeline_before_run')

        # Pipeline after_run comes last
        expect(order.last).to eq('2_pipeline_after_run')

        # Producer hooks surround producer execution
        gen_before_idx = order.index('3_producer_before')
        gen_block_idx = order.index('4_producer_block')
        gen_after_idx = order.index('5_producer_after')
        expect(gen_before_idx).to be < gen_block_idx
        expect(gen_block_idx).to be < gen_after_idx

        # Processor hooks surround processor execution
        proc_before_idx = order.index('6_processor_before')
        proc_block_idx = order.index('7_processor_block')
        proc_after_idx = order.index('8_processor_after')
        expect(proc_before_idx).to be < proc_block_idx
        expect(proc_block_idx).to be < proc_after_idx

        # Fork hooks happen in order (only if forking is supported)
        if Process.respond_to?(:fork)
          expect(order).to include('9_pipeline_before_fork')
          expect(order).to include('10_consumer_before_fork')
          expect(order).to include('11_consumer_after_fork')
          expect(order).to include('12_consumer_block')
          expect(order).to include('13_pipeline_after_fork')
        end
      ensure
        pipeline.cleanup
      end
    end
  end

  describe 'hooks with exceptions' do
    let(:error_in_hook_pipeline) do
      Class.new do
        include Minigun::DSL

        attr_accessor :results, :hook_error_caught

        def initialize
          @results = []
          @hook_error_caught = false
        end

        pipeline do
          producer :gen do
            emit(1)
          end

          after :gen do
            begin
              raise StandardError, "Error in hook"
            rescue StandardError => e
              @hook_error_caught = true
            end
          end

          consumer :collect do |item|
            @results << item
          end
        end
      end
    end

    it 'can handle errors within hooks' do
      pipeline = error_in_hook_pipeline.new
      pipeline.run

      expect(pipeline.hook_error_caught).to be true
      expect(pipeline.results).to eq([1])
    end
  end

  describe 'hooks accessing and modifying instance variables' do
    let(:stateful_pipeline) do
      Class.new do
        include Minigun::DSL

        attr_accessor :counter, :items_seen, :results

        def initialize
          @counter = 0
          @items_seen = []
          @results = []
        end

        pipeline do
          before :gen do
            @counter += 1
          end

          producer :gen do
            emit(10)
            emit(20)
          end

          after :gen do
            @counter += 10
          end

          before :transform do
            @items_seen << "about to transform"
          end

          processor :transform do |item|
            @items_seen << item
            emit(item * 2)
          end

          after :transform do
            @items_seen << "transformed"
          end

          consumer :collect do |item|
            @results << item
          end
        end
      end
    end

    it 'hooks can access and modify instance state' do
      pipeline = stateful_pipeline.new
      pipeline.run

      expect(pipeline.counter).to eq(11) # +1 before, +10 after
      expect(pipeline.items_seen).to include("about to transform", 10, 20, "transformed")
      expect(pipeline.results).to contain_exactly(20, 40)
    end
  end

  describe 'multiple hooks of same type on same stage' do
    let(:multi_hook_pipeline) do
      Class.new do
        include Minigun::DSL

        attr_accessor :events

        def initialize
          @events = []
        end

        pipeline do
          producer :gen do
            emit(1)
          end

          before :gen do
            @events << :before_1
          end

          before :gen do
            @events << :before_2
          end

          before :gen do
            @events << :before_3
          end

          after :gen do
            @events << :after_1
          end

          after :gen do
            @events << :after_2
          end

          consumer :collect do |item|
          end
        end
      end
    end

    it 'executes all hooks in order they were defined' do
      pipeline = multi_hook_pipeline.new
      pipeline.run

      # All before hooks should execute in order
      before_1_idx = pipeline.events.index(:before_1)
      before_2_idx = pipeline.events.index(:before_2)
      before_3_idx = pipeline.events.index(:before_3)

      expect(before_1_idx).to be < before_2_idx
      expect(before_2_idx).to be < before_3_idx

      # All after hooks should execute in order
      after_1_idx = pipeline.events.index(:after_1)
      after_2_idx = pipeline.events.index(:after_2)

      expect(after_1_idx).to be < after_2_idx
    end
  end

  describe 'mixed inline and named hooks' do
    let(:mixed_hooks_pipeline) do
      Class.new do
        include Minigun::DSL

        attr_accessor :events

        def initialize
          @events = []
        end

        pipeline do
          # Inline hook
          producer :gen,
                   before: -> { @events << :inline_before },
                   after: -> { @events << :inline_after } do
            @events << :gen_block
            emit(1)
          end

          # Named hook
          before :gen do
            @events << :named_before
          end

          after :gen do
            @events << :named_after
          end

          consumer :collect do |item|
          end
        end
      end
    end

    it 'executes both inline and named hooks' do
      pipeline = mixed_hooks_pipeline.new
      pipeline.run

      # Both inline and named hooks should fire
      expect(pipeline.events).to include(:inline_before, :inline_after)
      expect(pipeline.events).to include(:named_before, :named_after)

      # Check they're in reasonable order (all befores before block, all afters after block)
      gen_block_idx = pipeline.events.index(:gen_block)

      before_hooks = pipeline.events.select { |e| e.to_s.include?('before') }
      after_hooks = pipeline.events.select { |e| e.to_s.include?('after') }

      before_hooks.each do |hook|
        expect(pipeline.events.index(hook)).to be < gen_block_idx
      end

      after_hooks.each do |hook|
        expect(pipeline.events.index(hook)).to be > gen_block_idx
      end
    end
  end

  describe 'hook execution with routing' do
    let(:routing_pipeline) do
      Class.new do
        include Minigun::DSL

        attr_accessor :proc1_count, :proc2_count, :results

        def initialize
          @proc1_count = 0
          @proc2_count = 0
          @results = []
        end

        pipeline do
          producer :gen, to: [:proc1, :proc2] do
            emit(1)
            emit(2)
          end

          # Both processors get data from gen via fan-out routing
          processor :proc1, to: :collect do |item|
            emit(item * 10)
          end

          before(:proc1) do
            @proc1_count += 1
          end

          processor :proc2, to: :collect do |item|
            emit(item * 100)
          end

          before(:proc2) do
            @proc2_count += 1
          end

          consumer :collect do |item|
            @results << item
          end
        end
      end
    end

    it 'executes hooks for all routed stages' do
      pipeline = routing_pipeline.new
      pipeline.run

      # Each processor should have hooks executed for each item
      expect(pipeline.proc1_count).to eq(2) # 2 items
      expect(pipeline.proc2_count).to eq(2) # 2 items

      # Results from both processors
      expect(pipeline.results).to include(10, 20, 100, 200)
    end
  end

  describe 'hook with conditional logic' do
    let(:conditional_pipeline) do
      Class.new do
        include Minigun::DSL

        attr_accessor :results, :gc_runs

        def initialize
          @results = []
          @gc_runs = 0
          @item_count = 0
        end

        pipeline do
          producer :gen do
            10.times { |i| emit(i) }
          end

          before :transform do
            @item_count += 1
            # Run GC every 5 items
            if @item_count % 5 == 0
              GC.start
              @gc_runs += 1
            end
          end

          processor :transform do |item|
            emit(item * 2)
          end

          consumer :collect do |item|
            @results << item
          end
        end
      end
    end

    it 'can execute conditional logic in hooks' do
      pipeline = conditional_pipeline.new
      pipeline.run

      expect(pipeline.results.size).to eq(10)
      expect(pipeline.gc_runs).to eq(2) # At items 5 and 10
    end
  end
end

