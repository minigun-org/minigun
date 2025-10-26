# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'From Keyword' do
  describe 'from keyword for stages' do
    it 'connects stages in reverse (from: instead of to:)' do
      test_class = Class.new do
        include Minigun::DSL

        attr_accessor :results

        def initialize
          @results = []
          @mutex = Mutex.new
        end

        pipeline do
        producer :source, to: :double do
          3.times { |i| emit(i) }
        end
        end

        processor :double do |item|
          emit(item * 2)
        end

        # Use from: to connect from source and double
        consumer :collect, from: [:source, :double] do |item|
          @mutex.synchronize { @results << item }
        end
      end

      instance = test_class.new
      instance.run

      # Should have items from source (0,1,2) and from double (0,2,4)
      expect(instance.results.sort).to eq([0, 0, 1, 2, 2, 4])
    end

    it 'works with single from source' do
      test_class = Class.new do
        include Minigun::DSL

        attr_accessor :results

        def initialize
          @results = []
        end

        producer :gen do
          emit(10)
          emit(20)
        end

        consumer :save, from: :gen do |item|
          @results << item
        end
      end

      instance = test_class.new
      instance.run

      expect(instance.results.sort).to eq([10, 20])
    end

    it 'can mix to: and from:' do
      test_class = Class.new do
        include Minigun::DSL

        attr_accessor :results

        def initialize
          @results = []
          @mutex = Mutex.new
        end

        producer :a do
          emit(1)
        end

        # B receives from A using to:
        processor :b, to: :d do |item|
          emit(item + 10)
        end

        producer :c do
          emit(2)
        end

        # D receives from B (via to:) and C (via from:)
        consumer :d, from: :c do |item|
          @mutex.synchronize { @results << item }
        end
      end

      instance = test_class.new
      instance.run

      # Should have: 11 (from a->b->d) and 2 (from c->d)
      expect(instance.results.sort).to eq([2, 11])
    end
  end

  describe 'from keyword for pipelines' do
    it 'connects pipelines in reverse' do
      test_class = Class.new do
        include Minigun::DSL

        attr_accessor :results_a, :results_b

        def initialize
          @results_a = []
          @results_b = []
          @mutex = Mutex.new
        end

        pipeline :generate do
          producer :source do
            2.times { |i| emit(i) }
          end

          consumer :forward do |item|
            @mutex.synchronize { @results_a << item }
            emit(item * 10)
          end
        end

        # Use from: to connect from generate
        pipeline :process, from: :generate do
          consumer :save do |item|
            @mutex.synchronize { @results_b << item }
          end
        end
      end

      instance = test_class.new
      instance.run

      expect(instance.results_a.sort).to eq([0, 1])
      expect(instance.results_b.sort).to eq([0, 10])
    end

    it 'works with multiple from sources' do
      test_class = Class.new do
        include Minigun::DSL

        attr_accessor :results

        def initialize
          @results = []
          @mutex = Mutex.new
        end

        pipeline :source_a do
          producer :gen_a do
            emit('A')
          end

          consumer :out_a do |item|
            emit(item)
          end
        end

        pipeline :source_b do
          producer :gen_b do
            emit('B')
          end

          consumer :out_b do |item|
            emit(item)
          end
        end

        # Collect from both sources
        pipeline :collector, from: [:source_a, :source_b] do
          consumer :collect do |item|
            @mutex.synchronize { @results << item }
          end
        end
      end

      instance = test_class.new
      instance.run

      expect(instance.results.sort).to eq(['A', 'B'])
    end

    it 'can mix to: and from: in pipelines' do
      test_class = Class.new do
        include Minigun::DSL

        attr_accessor :results

        def initialize
          @results = []
          @mutex = Mutex.new
        end

        pipeline :a, to: :b do
          producer :gen do
            emit(1)
          end

          consumer :fwd do |item|
            emit(item)
          end
        end

        pipeline :b, to: :d do
          processor :transform do |item|
            emit(item + 10)
          end

          consumer :fwd do |item|
            emit(item)
          end
        end

        pipeline :c do
          producer :gen do
            emit(2)
          end

          consumer :fwd do |item|
            emit(item)
          end
        end

        # D receives from B (via to:) and C (via from:)
        pipeline :d, from: :c do
          consumer :collect do |item|
            @mutex.synchronize { @results << item }
          end
        end
      end

      instance = test_class.new
      instance.run

      expect(instance.results.sort).to eq([2, 11])
    end
  end
end

