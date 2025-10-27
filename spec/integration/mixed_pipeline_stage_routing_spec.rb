# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Mixed Pipeline and Stage Routing' do
  describe 'pipeline to stage routing' do
    it '1-to-1: single pipeline routes to single stage' do
      test_class = Class.new do
        include Minigun::DSL

        attr_accessor :results

        def initialize
          @results = []
          @mutex = Mutex.new
        end

        pipeline do
          # Stage that receives from pipeline
          processor :process do |item|
            output << item + 1
          end

          consumer :collect do |item|
            @mutex.synchronize { @results << item }
          end
        end

        # Pipeline that produces items
        pipeline :source, to: :process do
          producer :gen do
            3.times { |i| output << i }
          end

          consumer :forward do |item|
            output << item * 10
          end
        end
      end

      instance = test_class.new
      instance.run

      expect(instance.results.sort).to eq([1, 11, 21])
    end

    it '1-to-many: single pipeline routes to multiple stages' do
      test_class = Class.new do
        include Minigun::DSL

        attr_accessor :results_a, :results_b

        def initialize
          @results_a = []
          @results_b = []
          @mutex = Mutex.new
        end

        pipeline do
          processor :stage_a do |item|
            @mutex.synchronize { @results_a << item + 100 }
            output << item + 100
          end

          processor :stage_b do |item|
            @mutex.synchronize { @results_b << item + 200 }
            output << item + 200
          end

          consumer :collect do |item|
            # Collect final results
          end
        end

        # Pipeline routes to two stages
        pipeline :source, to: [:stage_a, :stage_b] do
          producer :gen do
            2.times { |i| output << i }
          end

          consumer :forward do |item|
            output << item * 10
          end
        end
      end

      instance = test_class.new
      instance.run

      expect(instance.results_a.sort).to eq([100, 110])
      expect(instance.results_b.sort).to eq([200, 210])
    end

    it 'many-to-1: multiple pipelines route to single stage' do
      test_class = Class.new do
        include Minigun::DSL

        attr_accessor :results

        def initialize
          @results = []
          @mutex = Mutex.new
        end

        pipeline do
          processor :merge_stage do |item|
            output << item * 100
          end

          consumer :collect do |item|
            @mutex.synchronize { @results << item }
          end
        end

        pipeline :source_a, to: :merge_stage do
          producer :gen do
            output << 1
          end

          consumer :fwd do |item|
            output << item
          end
        end

        pipeline :source_b, to: :merge_stage do
          producer :gen do
            output << 2
          end

          consumer :fwd do |item|
            output << item
          end
        end
      end

      instance = test_class.new
      instance.run

      expect(instance.results.sort).to eq([100, 200])
    end

    it 'many-to-many: multiple pipelines route to multiple stages' do
      test_class = Class.new do
        include Minigun::DSL

        attr_accessor :results_x, :results_y

        def initialize
          @results_x = []
          @results_y = []
          @mutex = Mutex.new
        end

        pipeline do
          processor :stage_x do |item|
            @mutex.synchronize { @results_x << item * 10 }
            output << item * 10
          end

          processor :stage_y do |item|
            @mutex.synchronize { @results_y << item * 20 }
            output << item * 20
          end

          consumer :collect do |item|
            # Final collection
          end
        end

        pipeline :source_a, to: [:stage_x, :stage_y] do
          producer :gen do
            output << 1
          end

          consumer :fwd do |item|
            output << item
          end
        end

        pipeline :source_b, to: [:stage_x, :stage_y] do
          producer :gen do
            output << 2
          end

          consumer :fwd do |item|
            output << item
          end
        end
      end

      instance = test_class.new
      instance.run

      expect(instance.results_x.sort).to eq([10, 20])
      expect(instance.results_y.sort).to eq([20, 40])
    end
  end

  describe 'stage to pipeline routing' do
    it '1-to-1: single stage routes to single pipeline' do
      test_class = Class.new do
        include Minigun::DSL

        attr_accessor :results

        def initialize
          @results = []
          @mutex = Mutex.new
        end

        pipeline do
          producer :source do
            3.times { |i| output << i }
          end

          # Stage routes to pipeline
          processor :transform, to: :receiver do |item|
            output << item * 10
          end
        end

        pipeline :receiver do
          processor :double do |item|
            output << item * 2
          end

          consumer :collect do |item|
            @mutex.synchronize { @results << item }
          end
        end
      end

      instance = test_class.new
      instance.run

      expect(instance.results.sort).to eq([0, 20, 40])
    end

    it '1-to-many: single stage routes to multiple pipelines' do
      test_class = Class.new do
        include Minigun::DSL

        attr_accessor :results_a, :results_b

        def initialize
          @results_a = []
          @results_b = []
          @mutex = Mutex.new
        end

        pipeline do
          producer :source do
            2.times { |i| output << i }
          end

          # Stage routes to two pipelines
          processor :split, to: [:pipe_a, :pipe_b] do |item|
            output << item * 10
          end
        end

        pipeline :pipe_a do
          processor :transform do |item|
            output << item + 100
          end

          consumer :collect do |item|
            @mutex.synchronize { @results_a << item }
          end
        end

        pipeline :pipe_b do
          processor :transform do |item|
            output << item + 200
          end

          consumer :collect do |item|
            @mutex.synchronize { @results_b << item }
          end
        end
      end

      instance = test_class.new
      instance.run

      expect(instance.results_a.sort).to eq([100, 110])
      expect(instance.results_b.sort).to eq([200, 210])
    end

    it 'many-to-1: multiple stages route to single pipeline' do
      test_class = Class.new do
        include Minigun::DSL

        attr_accessor :results

        def initialize
          @results = []
          @mutex = Mutex.new
        end

        pipeline do
          producer :source_a do
            output << 1
          end

          processor :stage_a, to: :receiver do |item|
            output << item * 10
          end

          producer :source_b do
            output << 2
          end

          processor :stage_b, to: :receiver do |item|
            output << item * 20
          end
        end

        pipeline :receiver do
          processor :transform do |item|
            output << item + 1000
          end

          consumer :collect do |item|
            @mutex.synchronize { @results << item }
          end
        end
      end

      instance = test_class.new
      instance.run

      expect(instance.results.sort).to eq([1010, 1040])
    end

    it 'many-to-many: multiple stages route to multiple pipelines' do
      test_class = Class.new do
        include Minigun::DSL

        attr_accessor :results_x, :results_y

        def initialize
          @results_x = []
          @results_y = []
          @mutex = Mutex.new
        end

        pipeline do
          producer :source_a do
            output << 1
          end

          processor :stage_a, to: [:pipe_x, :pipe_y] do |item|
            output << item * 10
          end

          producer :source_b do
            output << 2
          end

          processor :stage_b, to: [:pipe_x, :pipe_y] do |item|
            output << item * 20
          end
        end

        pipeline :pipe_x do
          processor :transform do |item|
            output << item + 100
          end

          consumer :collect do |item|
            @mutex.synchronize { @results_x << item }
          end
        end

        pipeline :pipe_y do
          processor :transform do |item|
            output << item + 200
          end

          consumer :collect do |item|
            @mutex.synchronize { @results_y << item }
          end
        end
      end

      instance = test_class.new
      instance.run

      expect(instance.results_x.sort).to eq([110, 140])
      expect(instance.results_y.sort).to eq([210, 240])
    end
  end

  describe 'pipeline from stage routing' do
    it '1-to-1: single pipeline receives from single stage' do
      test_class = Class.new do
        include Minigun::DSL

        attr_accessor :results

        def initialize
          @results = []
          @mutex = Mutex.new
        end

        pipeline do
          producer :source do
            3.times { |i| output << i }
          end

          processor :transform do |item|
            output << item * 10
          end
        end

        # Pipeline receives from stage using from:
        pipeline :receiver, from: :transform do
          processor :double do |item|
            output << item * 2
          end

          consumer :collect do |item|
            @mutex.synchronize { @results << item }
          end
        end
      end

      instance = test_class.new
      instance.run

      expect(instance.results.sort).to eq([0, 20, 40])
    end

    it '1-to-many: single pipeline receives from multiple stages' do
      test_class = Class.new do
        include Minigun::DSL

        attr_accessor :results

        def initialize
          @results = []
          @mutex = Mutex.new
        end

        pipeline do
          producer :source_a do
            output << 1
          end

          processor :stage_a do |item|
            output << item * 10
          end

          producer :source_b do
            output << 2
          end

          processor :stage_b do |item|
            output << item * 20
          end
        end

        # Pipeline receives from multiple stages
        pipeline :receiver, from: [:stage_a, :stage_b] do
          processor :add do |item|
            output << item + 1000
          end

          consumer :collect do |item|
            @mutex.synchronize { @results << item }
          end
        end
      end

      instance = test_class.new
      instance.run

      expect(instance.results.sort).to eq([1010, 1040])
    end

    it 'many-to-1: multiple pipelines receive from single stage' do
      test_class = Class.new do
        include Minigun::DSL

        attr_accessor :results_a, :results_b

        def initialize
          @results_a = []
          @results_b = []
          @mutex = Mutex.new
        end

        pipeline do
          producer :source do
            2.times { |i| output << i }
          end

          processor :broadcaster do |item|
            output << item * 10
          end
        end

        # Multiple pipelines receive from same stage
        pipeline :receiver_a, from: :broadcaster do
          processor :transform do |item|
            output << item + 100
          end

          consumer :collect do |item|
            @mutex.synchronize { @results_a << item }
          end
        end

        pipeline :receiver_b, from: :broadcaster do
          processor :transform do |item|
            output << item + 200
          end

          consumer :collect do |item|
            @mutex.synchronize { @results_b << item }
          end
        end
      end

      instance = test_class.new
      instance.run

      expect(instance.results_a.sort).to eq([100, 110])
      expect(instance.results_b.sort).to eq([200, 210])
    end

    it 'many-to-many: multiple pipelines receive from multiple stages' do
      test_class = Class.new do
        include Minigun::DSL

        attr_accessor :results_x, :results_y

        def initialize
          @results_x = []
          @results_y = []
          @mutex = Mutex.new
        end

        pipeline do
          producer :source_a do
            output << 1
          end

          processor :stage_a do |item|
            output << item * 10
          end

          producer :source_b do
            output << 2
          end

          processor :stage_b do |item|
            output << item * 20
          end
        end

        # Multiple pipelines receive from multiple stages
        pipeline :pipe_x, from: [:stage_a, :stage_b] do
          processor :transform do |item|
            output << item + 100
          end

          consumer :collect do |item|
            @mutex.synchronize { @results_x << item }
          end
        end

        pipeline :pipe_y, from: [:stage_a, :stage_b] do
          processor :transform do |item|
            output << item + 200
          end

          consumer :collect do |item|
            @mutex.synchronize { @results_y << item }
          end
        end
      end

      instance = test_class.new
      instance.run

      expect(instance.results_x.sort).to eq([110, 140])
      expect(instance.results_y.sort).to eq([210, 240])
    end
  end

  describe 'stage from pipeline routing' do
    it '1-to-1: single stage receives from single pipeline' do
      test_class = Class.new do
        include Minigun::DSL

        attr_accessor :results

        def initialize
          @results = []
          @mutex = Mutex.new
        end

        pipeline do
          # Stage receives from pipeline using from:
          processor :transform, from: :source do |item|
            output << item + 1
          end

          consumer :collect do |item|
            @mutex.synchronize { @results << item }
          end
        end

        pipeline :source do
          producer :gen do
            3.times { |i| output << i }
          end

          consumer :forward do |item|
            output << item * 10
          end
        end
      end

      instance = test_class.new
      instance.run

      expect(instance.results.sort).to eq([1, 11, 21])
    end

    it '1-to-many: single stage receives from multiple pipelines' do
      test_class = Class.new do
        include Minigun::DSL

        attr_accessor :results

        def initialize
          @results = []
          @mutex = Mutex.new
        end

        pipeline do
          # Stage receives from multiple pipelines
          processor :merge, from: [:source_a, :source_b] do |item|
            output << item + 1000
          end

          consumer :collect do |item|
            @mutex.synchronize { @results << item }
          end
        end

        pipeline :source_a do
          producer :gen do
            output << 1
          end

          consumer :fwd do |item|
            output << item * 10
          end
        end

        pipeline :source_b do
          producer :gen do
            output << 2
          end

          consumer :fwd do |item|
            output << item * 20
          end
        end
      end

      instance = test_class.new
      instance.run

      expect(instance.results.sort).to eq([1010, 1040])
    end

    it 'many-to-1: multiple stages receive from single pipeline' do
      test_class = Class.new do
        include Minigun::DSL

        attr_accessor :results_a, :results_b

        def initialize
          @results_a = []
          @results_b = []
          @mutex = Mutex.new
        end

        pipeline do
          # Multiple stages receive from same pipeline
          processor :stage_a, from: :source do |item|
            @mutex.synchronize { @results_a << item + 100 }
            output << item + 100
          end

          processor :stage_b, from: :source do |item|
            @mutex.synchronize { @results_b << item + 200 }
            output << item + 200
          end

          consumer :collect do |item|
            # Final collection
          end
        end

        pipeline :source do
          producer :gen do
            2.times { |i| output << i }
          end

          consumer :forward do |item|
            output << item * 10
          end
        end
      end

      instance = test_class.new
      instance.run

      expect(instance.results_a.sort).to eq([100, 110])
      expect(instance.results_b.sort).to eq([200, 210])
    end

    it 'many-to-many: multiple stages receive from multiple pipelines' do
      test_class = Class.new do
        include Minigun::DSL

        attr_accessor :results_x, :results_y

        def initialize
          @results_x = []
          @results_y = []
          @mutex = Mutex.new
        end

        pipeline do
          # Multiple stages receive from multiple pipelines
          processor :stage_x, from: [:source_a, :source_b] do |item|
            @mutex.synchronize { @results_x << item + 100 }
            output << item + 100
          end

          processor :stage_y, from: [:source_a, :source_b] do |item|
            @mutex.synchronize { @results_y << item + 200 }
            output << item + 200
          end

          consumer :collect do |item|
            # Final collection
          end
        end

        pipeline :source_a do
          producer :gen do
            output << 1
          end

          consumer :fwd do |item|
            output << item * 10
          end
        end

        pipeline :source_b do
          producer :gen do
            output << 2
          end

          consumer :fwd do |item|
            output << item * 20
          end
        end
      end

      instance = test_class.new
      instance.run

      expect(instance.results_x.sort).to eq([110, 140])
      expect(instance.results_y.sort).to eq([210, 240])
    end
  end
end

