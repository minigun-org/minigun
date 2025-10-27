# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'emit_to_stage v2' do
  describe 'basic functionality' do
    it 'routes items to explicitly named stage', timeout: 10 do
      klass = Class.new do
        include Minigun::DSL
        attr_accessor :results

        def initialize
          @results = []
        end

        pipeline do
          producer :gen do |output|
            output << { id: 1, route: :fast }
            output << { id: 2, route: :slow }
            output << { id: 3, route: :fast }
          end

          processor :router do |item, output|
            output.to(item[:route]) << item
          end

          consumer :fast do |item|
            @results << { stage: :fast, id: item[:id] }
          end

          consumer :slow do |item|
            @results << { stage: :slow, id: item[:id] }
          end
        end
      end

      pipeline = klass.new
      pipeline.run

      expect(pipeline.results.size).to eq(3)
      expect(pipeline.results.select { |r| r[:stage] == :fast }.size).to eq(2)
      expect(pipeline.results.select { |r| r[:stage] == :slow }.size).to eq(1)
      expect(pipeline.results.map { |r| r[:id] }.sort).to eq([1, 2, 3])
    end

    it 'allows mixing emit and emit_to_stage in same stage' do
      klass = Class.new do
        include Minigun::DSL
        attr_accessor :results

        def initialize
          @results = []
        end

        pipeline do
          producer :gen do |output|
            output << 1
            output << 2
          end

          processor :router do |item, output|
            if item == 1
              output << item * 10  # Regular emit - goes to next stage via DAG
            else
              output.to(:special) << item * 100  # Targeted emit
            end
          end

          consumer :normal do |item|
            @results << { stage: :normal, value: item }
          end

          consumer :special do |item|
            @results << { stage: :special, value: item }
          end
        end
      end

      pipeline = klass.new
      pipeline.run

      expect(pipeline.results.size).to eq(2)
      expect(pipeline.results).to include({ stage: :normal, value: 10 })
      expect(pipeline.results).to include({ stage: :special, value: 200 })
    end

    it 'can emit_to_stage multiple times in single stage' do
      klass = Class.new do
        include Minigun::DSL
        attr_accessor :results

        def initialize
          @results = []
        end

        pipeline do
          producer :gen do |output|
            output << { value: 100 }
          end

          processor :splitter do |item, output|
            output.to(:consumer_a) << { stage: 'A', value: item[:value] }
            output.to(:consumer_b) << { stage: 'B', value: item[:value] * 2 }
            output.to(:consumer_c) << { stage: 'C', value: item[:value] * 3 }
          end

          consumer :consumer_a do |item|
            @results << item
          end

          consumer :consumer_b do |item|
            @results << item
          end

          consumer :consumer_c do |item|
            @results << item
          end
        end
      end

      pipeline = klass.new
      pipeline.run

      expect(pipeline.results.size).to eq(3)
      expect(pipeline.results).to include({ stage: 'A', value: 100 })
      expect(pipeline.results).to include({ stage: 'B', value: 200 })
      expect(pipeline.results).to include({ stage: 'C', value: 300 })
    end
  end

  describe 'complex routing patterns' do
    it 'supports conditional routing logic' do
      klass = Class.new do
        include Minigun::DSL
        attr_accessor :results

        def initialize
          @results = []
        end

        pipeline do
          producer :gen do |output|
            5.times { |i| output << i }
          end

          processor :router do |item, output|
            case item
            when 0..2
              output.to(:low) << item
            when 3..4
              output.to(:high) << item
            end
          end

          consumer :low do |item|
            @results << { type: :low, value: item }
          end

          consumer :high do |item|
            @results << { type: :high, value: item }
          end
        end
      end

      pipeline = klass.new
      pipeline.run

      expect(pipeline.results.size).to eq(5)
      expect(pipeline.results.select { |r| r[:type] == :low }.size).to eq(3)
      expect(pipeline.results.select { |r| r[:type] == :high }.size).to eq(2)
    end

    it 'supports load balancing pattern' do
      klass = Class.new do
        include Minigun::DSL
        attr_accessor :results

        def initialize
          @results = []
          @current_worker = 0
        end

        pipeline do
          producer :gen do |output|
            10.times { |i| output << i }
          end

          processor :load_balancer do |item, output|
            worker = :"worker_#{@current_worker}"
            @current_worker = (@current_worker + 1) % 3
            output.to(worker) << item
          end

          consumer :worker_0 do |item|
            @results << { worker: 0, value: item }
          end

          consumer :worker_1 do |item|
            @results << { worker: 1, value: item }
          end

          consumer :worker_2 do |item|
            @results << { worker: 2, value: item }
          end
        end
      end

      pipeline = klass.new
      pipeline.run

      expect(pipeline.results.size).to eq(10)
      expect(pipeline.results.select { |r| r[:worker] == 0 }.size).to eq(4)
      expect(pipeline.results.select { |r| r[:worker] == 1 }.size).to eq(3)
      expect(pipeline.results.select { |r| r[:worker] == 2 }.size).to eq(3)
    end

    it 'supports multi-level routing' do
      klass = Class.new do
        include Minigun::DSL
        attr_accessor :results

        def initialize
          @results = []
        end

        pipeline do
          producer :gen do |output|
            output << { type: 'A', priority: :high }
            output << { type: 'B', priority: :low }
            output << { type: 'A', priority: :low }
          end

          processor :type_router do |item, output|
            output.to(:"#{item[:type].downcase}_processor") << item
          end

          processor :a_processor do |item, output|
            output.to(:"#{item[:priority]}_priority") << item.merge(processed: 'A')
          end

          processor :b_processor do |item, output|
            output.to(:"#{item[:priority]}_priority") << item.merge(processed: 'B')
          end

          consumer :high_priority do |item|
            @results << item
          end

          consumer :low_priority do |item|
            @results << item
          end
        end
      end

      pipeline = klass.new
      pipeline.run

      expect(pipeline.results.size).to eq(3)
      expect(pipeline.results.select { |r| r[:priority] == :high }.size).to eq(1)
      expect(pipeline.results.select { |r| r[:priority] == :low }.size).to eq(2)
    end
  end

  describe 'execution context integration' do
    it 'works with threaded consumers', timeout: 5 do
      klass = Class.new do
        include Minigun::DSL
        attr_accessor :results

        def initialize
          @results = []
          @mutex = Mutex.new
        end

        pipeline do
          producer :gen do |output|
            5.times { |i| output << i }
          end

          processor :router do |item, output|
            if item < 3
              output.to(:worker1) << item
            else
              output.to(:worker2) << item
            end
          end

          threads(2) do
            consumer :worker1 do |item|
              @mutex.synchronize do
                @results << { worker: 1, value: item }
              end
            end

            consumer :worker2 do |item|
              @mutex.synchronize do
                @results << { worker: 2, value: item }
              end
            end
          end
        end
      end

      pipeline = klass.new
      pipeline.run

      expect(pipeline.results.size).to eq(5)
      expect(pipeline.results.select { |r| r[:worker] == 1 }.size).to eq(3)
      expect(pipeline.results.select { |r| r[:worker] == 2 }.size).to eq(2)
    end

    it 'works across different execution contexts', timeout: 5 do
      klass = Class.new do
        include Minigun::DSL
        attr_accessor :results

        def initialize
          @results = []
          @mutex = Mutex.new
        end

        pipeline do
          producer :gen do |output|
            2.times { |i| output << i }
          end

          # Inline router
          processor :router do |item, output|
            if item == 0
              output.to(:threaded_consumer) << item
            else
              output.to(:inline_consumer) << item
            end
          end

          threads(1) do
            consumer :threaded_consumer do |item|
              @mutex.synchronize do
                @results << { type: 'threaded', value: item }
              end
            end
          end

          consumer :inline_consumer do |item|
            @mutex.synchronize do
              @results << { type: 'inline', value: item }
            end
          end
        end
      end

      pipeline = klass.new
      pipeline.run

      expect(pipeline.results.size).to eq(2)
      expect(pipeline.results).to include({ type: 'threaded', value: 0 })
      expect(pipeline.results).to include({ type: 'inline', value: 1 })
    end
  end

  describe 'batching with emit_to_stage' do
    it 'supports custom batching with dynamic routing' do
      klass = Class.new do
        include Minigun::DSL
        attr_accessor :results

        def initialize
          @results = []
          @mutex = Mutex.new
        end

        pipeline do
          producer :gen do |output|
            output << { type: 'email', id: 1 }
            output << { type: 'sms', id: 2 }
            output << { type: 'email', id: 3 }
            output << { type: 'sms', id: 4 }
          end

          processor :message_batcher do |message, output|
            @batches ||= Hash.new { |h, k| h[k] = [] }

            @batches[message[:type]] << message

            if @batches[message[:type]].size >= 2
              output.to(:"#{message[:type]}_sender") << @batches[message[:type]].dup
              @batches[message[:type]].clear
            end
          end

          consumer :email_sender do |batch|
            @mutex.synchronize do
              @results << { type: 'email', count: batch.size }
            end
          end

          consumer :sms_sender do |batch|
            @mutex.synchronize do
              @results << { type: 'sms', count: batch.size }
            end
          end
        end
      end

      pipeline = klass.new
      pipeline.run

      expect(pipeline.results.size).to eq(2)
      expect(pipeline.results).to include({ type: 'email', count: 2 })
      expect(pipeline.results).to include({ type: 'sms', count: 2 })
    end
  end
end

