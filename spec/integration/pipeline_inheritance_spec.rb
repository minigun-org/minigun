# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Pipeline Inheritance' do
  before do
    allow(Minigun.logger).to receive(:info)
  end

  describe 'single unnamed pipeline' do
    it 'evaluates stages directly on root_pipeline' do
      klass = Class.new do
        include Minigun::DSL

        attr_accessor :results

        def initialize
          @results = []
        end

        pipeline do
          producer :source do |output|
            [1, 2, 3].each { |n| output << n }
          end

          consumer :collect do |n|
            @results << n
          end
        end
      end

      task = klass.new
      task.run
      expect(task.results.sort).to eq([1, 2, 3])
    end
  end

  describe 'multiple unnamed pipelines in same class' do
    it 'combines all stages on root_pipeline' do
      klass = Class.new do
        include Minigun::DSL

        attr_accessor :results_a, :results_b

        def initialize
          @results_a = []
          @results_b = []
          @mutex = Mutex.new
        end

        # First unnamed pipeline
        pipeline do
          producer :source_a do |output|
            output << 'A1'
            output << 'A2'
          end

          consumer :collect_a do |item|
            @mutex.synchronize { @results_a << item }
          end
        end

        # Second unnamed pipeline - stages also go on root
        pipeline do
          producer :source_b do |output|
            output << 'B1'
            output << 'B2'
          end

          consumer :collect_b do |item|
            @mutex.synchronize { @results_b << item }
          end
        end
      end

      task = klass.new
      task.run
      expect(task.results_a.sort).to eq(%w[A1 A2])
      expect(task.results_b.sort).to eq(%w[B1 B2])
    end
  end

  describe 'named pipeline extension' do
    it 'extends named pipeline when declared again in same class' do
      klass = Class.new do
        include Minigun::DSL

        attr_accessor :results

        def initialize
          @results = []
          @mutex = Mutex.new
        end

        pipeline :main do
          producer :source do |output|
            [1, 2, 3].each { |n| output << n }
          end

          consumer :collect do |n|
            @mutex.synchronize { @results << n }
          end
        end

        # Extend the :main pipeline
        pipeline :main do
          processor :double do |n, output|
            output << (n * 2)
          end

          reroute_stage :source, to: :double
          reroute_stage :double, to: :collect
        end
      end

      task = klass.new
      task.run
      expect(task.results.sort).to eq([2, 4, 6])
    end
  end

  describe 'inheritance with unnamed pipelines' do
    let(:parent_class) do
      Class.new do
        include Minigun::DSL

        attr_accessor :results

        def initialize
          @results = []
          @mutex = Mutex.new
        end

        pipeline do
          producer :source do |output|
            [1, 2, 3].each { |n| output << n }
          end

          consumer :collect do |n|
            @mutex.synchronize { @results << n }
          end
        end
      end
    end

    it 'child inherits parent stages' do
      child_class = Class.new(parent_class)

      task = child_class.new
      task.run
      expect(task.results.sort).to eq([1, 2, 3])
    end

    it 'child can add stages and reroute' do
      child_class = Class.new(parent_class) do
        pipeline do
          processor :double do |n, output|
            output << (n * 2)
          end

          reroute_stage :source, to: :double
          reroute_stage :double, to: :collect
        end
      end

      task = child_class.new
      task.run
      expect(task.results.sort).to eq([2, 4, 6])
    end

    it 'parent is unaffected by child changes' do
      # Define child that modifies pipeline
      Class.new(parent_class) do
        pipeline do
          processor :double do |n, output|
            output << (n * 2)
          end

          reroute_stage :source, to: :double
          reroute_stage :double, to: :collect
        end
      end

      # Parent should still work as before
      parent = parent_class.new
      parent.run
      expect(parent.results.sort).to eq([1, 2, 3])
    end
  end

  describe 'inheritance with named pipelines' do
    let(:parent_class) do
      Class.new do
        include Minigun::DSL

        attr_accessor :results

        def initialize
          @results = []
          @mutex = Mutex.new
        end

        pipeline :main do
          producer :source do |output|
            [10, 20].each { |n| output << n }
          end

          consumer :collect do |n|
            @mutex.synchronize { @results << n }
          end
        end
      end
    end

    it 'child can extend parent named pipeline' do
      child_class = Class.new(parent_class) do
        # Extend the :main pipeline by declaring it again
        pipeline :main do
          processor :add_five do |n, output|
            output << (n + 5)
          end

          reroute_stage :source, to: :add_five
          reroute_stage :add_five, to: :collect
        end
      end

      task = child_class.new
      task.run
      expect(task.results.sort).to eq([15, 25])
    end

    it 'child can add new named pipeline' do
      child_class = Class.new(parent_class) do
        pipeline :secondary do
          producer :source2 do |output|
            [100, 200].each { |n| output << n }
          end

          consumer :collect2 do |n|
            @mutex.synchronize { @results << n }
          end
        end
      end

      task = child_class.new
      task.run
      # Results from both pipelines
      expect(task.results.sort).to eq([10, 20, 100, 200])
    end
  end

  describe 'multi-level inheritance' do
    let(:grandparent_class) do
      Class.new do
        include Minigun::DSL

        attr_accessor :events

        def initialize
          @events = []
          @mutex = Mutex.new
        end

        pipeline do
          producer :source do |output|
            output << :grandparent_item
          end

          consumer :collect do |item|
            @mutex.synchronize { @events << item }
          end
        end
      end
    end

    let(:parent_class) do
      Class.new(grandparent_class) do
        pipeline do
          processor :add_parent do |item, output|
            output << "#{item}_parent"
          end

          reroute_stage :source, to: :add_parent
          reroute_stage :add_parent, to: :collect
        end
      end
    end

    let(:child_class) do
      Class.new(parent_class) do
        pipeline do
          processor :add_child do |item, output|
            output << "#{item}_child"
          end

          reroute_stage :add_parent, to: :add_child
          reroute_stage :add_child, to: :collect
        end
      end
    end

    it 'grandchild inherits all ancestor stages' do
      task = child_class.new
      task.run
      expect(task.events).to eq(['grandparent_item_parent_child'])
    end

    it 'each level can run independently' do
      gp = grandparent_class.new
      gp.run
      expect(gp.events).to eq([:grandparent_item])

      p = parent_class.new
      p.run
      expect(p.events).to eq(['grandparent_item_parent'])
    end
  end

  describe 'mixed named and unnamed pipelines' do
    it 'unnamed provides stages that named pipelines route to' do
      klass = Class.new do
        include Minigun::DSL

        attr_accessor :results

        def initialize
          @results = []
          @mutex = Mutex.new
        end

        # Unnamed pipeline provides shared stages on root
        pipeline do
          processor :transform do |item, output|
            output << (item * 10)
          end

          consumer :collect do |item|
            @mutex.synchronize { @results << item }
          end
        end

        # Named pipeline routes to shared stage
        pipeline :producer_pipeline, to: :transform do
          producer :source do |output|
            [1, 2, 3].each { |n| output << n }
          end

          consumer :forward do |item, output|
            output << item
          end
        end
      end

      task = klass.new
      task.run
      expect(task.results.sort).to eq([10, 20, 30])
    end

    it 'multiple named pipelines can route to same shared stage' do
      klass = Class.new do
        include Minigun::DSL

        attr_accessor :results

        def initialize
          @results = []
          @mutex = Mutex.new
        end

        pipeline do
          consumer :collect do |item|
            @mutex.synchronize { @results << item }
          end
        end

        pipeline :pipeline_a, to: :collect do
          producer :source_a do |output|
            output << 'A'
          end

          consumer :forward_a do |item, output|
            output << "#{item}_processed"
          end
        end

        pipeline :pipeline_b, to: :collect do
          producer :source_b do |output|
            output << 'B'
          end

          consumer :forward_b do |item, output|
            output << "#{item}_processed"
          end
        end
      end

      task = klass.new
      task.run
      expect(task.results.sort).to eq(%w[A_processed B_processed])
    end
  end

  describe 'source tracking' do
    it 'tracks source of pipeline blocks' do
      parent = Class.new do
        include Minigun::DSL

        pipeline do
          producer :source do |output|
            output << 1
          end
        end
      end

      child = Class.new(parent) do
        pipeline do
          consumer :collect do |_item|
            # consume
          end
        end
      end

      blocks = child._pipeline_definition_blocks

      expect(blocks.size).to eq(2)
      expect(blocks[0][:source]).to eq(:inherited)
      expect(blocks[1][:source]).to eq(:self)
    end
  end

  describe 'edge cases' do
    it 'handles empty pipeline block' do
      klass = Class.new do
        include Minigun::DSL

        attr_accessor :results

        def initialize
          @results = []
        end

        pipeline do
          # Empty - should not break
        end
      end

      task = klass.new
      expect { task.run }.not_to raise_error
    end

    it 'handles class with no pipeline blocks' do
      klass = Class.new do
        include Minigun::DSL

        def initialize
          @results = []
        end
      end

      task = klass.new
      expect { task.run }.not_to raise_error
    end

    it 'allows child to skip adding stages' do
      parent = Class.new do
        include Minigun::DSL

        attr_accessor :results

        def initialize
          @results = []
        end

        pipeline do
          producer :source do |output|
            [1, 2, 3].each { |n| output << n }
          end

          consumer :collect do |n|
            @results << n
          end
        end
      end

      # Child inherits but doesn't add anything
      child = Class.new(parent)

      task = child.new
      task.run
      expect(task.results.sort).to eq([1, 2, 3])
    end
  end
end
