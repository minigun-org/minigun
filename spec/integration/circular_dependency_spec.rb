# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Circular Dependency Detection' do
  describe 'stage-level cycles' do
    it 'raises error for direct self-loop' do
      expect {
        Class.new do
          include Minigun::DSL

          pipeline do
            # A stage that routes to itself
            processor :loop_stage, to: :loop_stage do |item, output|
              output << item
            end
          end
        end.new.run
      }.to raise_error(Minigun::Error, /Circular dependency/)
    end

    it 'raises error for simple A->B->A cycle' do
      expect {
        Class.new do
          include Minigun::DSL

          pipeline do
            processor :a, to: :b do |item, output|
              output << item
            end

            processor :b, to: :a do |item, output|
              output << item
            end
          end
        end.new.run
      }.to raise_error(Minigun::Error, /Circular dependency/)
    end

    it 'raises error for A->B->C->A cycle' do
      expect {
        Class.new do
          include Minigun::DSL

          pipeline do
            processor :a, to: :b do |item, output|
              output << item
            end

            processor :b, to: :c do |item, output|
              output << item
            end

            processor :c, to: :a do |item, output|
              output << item
            end
          end
        end.new.run
      }.to raise_error(Minigun::Error, /Circular dependency/)
    end

    it 'raises error with from: causing cycle' do
      expect {
        Class.new do
          include Minigun::DSL

          pipeline do
            processor :a, to: :b do |item, output|
              output << item
            end

            # from: :c means c->b, creating b->c and c->b cycle when combined with b->c
            processor :b, to: :c, from: :c do |item, output|
              output << item
            end

            processor :c do |item, output|
              output << item
            end
          end
        end.new.run
      }.to raise_error(Minigun::Error, /Circular dependency/)
    end

    it 'allows diamond patterns (no cycle)' do
      test_class = Class.new do
        include Minigun::DSL

        attr_accessor :results

        def initialize
          @results = []
          @mutex = Mutex.new
        end

        pipeline do
          producer :source do |output|
            output << 1
          end

          # Diamond pattern: source -> left -> merge
          #                   source -> right -> merge
          processor :left, from: :source, to: :merge do |item, output|
            output << item + 10
          end

          processor :right, from: :source, to: :merge do |item, output|
            output << item + 20
          end

          consumer :merge do |item|
            @mutex.synchronize { @results << item }
          end
        end
      end

      instance = test_class.new
      expect { instance.run }.not_to raise_error

      expect(instance.results.sort).to eq([11, 21])
    end

    it 'allows complex DAG without cycles' do
      test_class = Class.new do
        include Minigun::DSL

        attr_accessor :results

        def initialize
          @results = []
          @mutex = Mutex.new
        end

        pipeline do
          producer :start do |output|
            output << 1
          end

          processor :a, from: :start do |item, output|
            output << item + 1
          end

          processor :b, from: :start do |item, output|
            output << item + 2
          end

          processor :c, from: [:a, :b] do |item, output|
            output << item + 10
          end

          processor :d, from: :a do |item, output|
            output << item + 20
          end

          consumer :end_stage, from: [:c, :d] do |item|
            @mutex.synchronize { @results << item }
          end
        end
      end

      instance = test_class.new
      expect { instance.run }.not_to raise_error

      # start(1) -> a(2) -> c(12), d(22)
      # start(1) -> b(3) -> c(13)
      expect(instance.results.sort).to eq([12, 13, 22])
    end
  end

  describe 'pipeline-level cycles' do
    it 'raises error for pipeline A->B->A cycle' do
      expect {
        Class.new do
          include Minigun::DSL

          pipeline :a, to: :b do
            producer :gen do |output|
              output << 1
            end

            consumer :fwd do |item|
              output << item
            end
          end

          pipeline :b, to: :a do
            consumer :collect do |_item|
              # no-op
            end
          end
        end.new.run
      }.to raise_error(Minigun::Error, /Circular dependency/)
    end

    it 'raises error for pipeline self-loop' do
      expect {
        Class.new do
          include Minigun::DSL

          pipeline :loop, to: :loop do
            producer :gen do |output|
              output << 1
            end

            consumer :collect do |_item|
              # no-op
            end
          end
        end.new.run
      }.to raise_error(Minigun::Error, /Circular dependency/)
    end

    it 'raises error with from: causing pipeline cycle' do
      expect {
        Class.new do
          include Minigun::DSL

          pipeline :a, to: :b do
            producer :gen do |output|
              output << 1
            end

            consumer :fwd do |item|
              output << item
            end
          end

          # from: :c means c->b, but b->c exists, creating cycle
          pipeline :b, to: :c, from: :c do
            consumer :collect do |_item|
              # no-op
            end
          end

          pipeline :c do
            consumer :collect do |_item|
              # no-op
            end
          end
        end.new.run
      }.to raise_error(Minigun::Error, /Circular dependency/)
    end

    it 'allows diamond pattern in pipelines' do
      test_class = Class.new do
        include Minigun::DSL

        attr_accessor :results

        def initialize
          @results = []
          @mutex = Mutex.new
        end

        pipeline :source, to: [:left, :right] do
          producer :gen do |output|
            output << 1
          end

          consumer :fwd do |item, output|
            output << item
          end
        end

        pipeline :left, to: :merge do
          processor :transform do |item, output|
            output << item + 10
          end

          consumer :fwd do |item, output|
            output << item
          end
        end

        pipeline :right, to: :merge do
          processor :transform do |item, output|
            output << item + 20
          end

          consumer :fwd do |item, output|
            output << item
          end
        end

        pipeline :merge do
          consumer :collect do |item|
            @mutex.synchronize { @results << item }
          end
        end
      end

      instance = test_class.new
      expect { instance.run }.not_to raise_error

      expect(instance.results.sort).to eq([11, 21])
    end
  end
end

