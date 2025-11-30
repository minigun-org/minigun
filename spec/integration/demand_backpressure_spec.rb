# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Demand-based backpressure' do
  describe 'basic demand flow' do
    it 'processes all items with demand enabled' do
      results = []
      mutex = Mutex.new

      task = Class.new do
        include Minigun::DSL

        pipeline demand: true do
          producer :source do |output|
            100.times { |i| output << i }
          end

          consumer :processor do |item, output|
            output << (item * 2)
          end

          consumer :sink do |item|
            mutex.synchronize { results << item }
          end
        end
      end

      task.new.run

      expect(results.size).to eq(100)
      expect(results.sort).to eq((0...100).map { |i| i * 2 })
    end

    it 'works with custom min_demand and max_demand' do
      results = []
      mutex = Mutex.new

      task = Class.new do
        include Minigun::DSL

        pipeline demand: true do
          producer :source do |output|
            50.times { |i| output << i }
          end

          consumer :processor, min_demand: 10, max_demand: 25 do |item, output|
            output << (item + 1)
          end

          consumer :sink do |item|
            mutex.synchronize { results << item }
          end
        end
      end

      task.new.run

      expect(results.size).to eq(50)
      expect(results.sort).to eq((1..50).to_a)
    end
  end

  describe 'backpressure behavior' do
    it 'producer waits for consumer demand' do
      consumed_count = Concurrent::AtomicFixnum.new(0)

      task = Class.new do
        include Minigun::DSL

        pipeline demand: true do
          producer :fast_producer do |output|
            20.times do |i|
              output << i
            end
          end

          # Slow consumer with small demand buffer
          consumer :slow_consumer, min_demand: 2, max_demand: 5 do |_item|
            sleep 0.01 # Simulate slow processing
            consumed_count.increment
          end
        end
      end

      task.new.run

      # All items should be consumed
      expect(consumed_count.value).to eq(20)
    end
  end

  describe 'demand disabled' do
    it 'works normally without demand (uses queue backpressure)' do
      results = []
      mutex = Mutex.new

      task = Class.new do
        include Minigun::DSL

        pipeline do # No demand: true
          producer :source do |output|
            50.times { |i| output << i }
          end

          consumer :sink do |item|
            mutex.synchronize { results << item }
          end
        end
      end

      task.new.run

      expect(results.size).to eq(50)
    end
  end

  describe 'multi-stage pipeline' do
    it 'propagates demand through multiple stages' do
      results = []
      mutex = Mutex.new

      task = Class.new do
        include Minigun::DSL

        pipeline demand: true do
          producer :source do |output|
            30.times { |i| output << i }
          end

          consumer :stage1 do |item, output|
            output << (item + 1)
          end

          consumer :stage2 do |item, output|
            output << (item * 2)
          end

          consumer :stage3 do |item|
            mutex.synchronize { results << item }
          end
        end
      end

      task.new.run

      expect(results.size).to eq(30)
      # (i + 1) * 2 for i in 0..29
      expect(results.sort).to eq((0...30).map { |i| (i + 1) * 2 })
    end
  end

  describe 'demand mode: disabled' do
    it 'skips demand tracking when mode is disabled' do
      results = []
      mutex = Mutex.new

      task = Class.new do
        include Minigun::DSL

        pipeline demand: true do
          producer :source do |output|
            20.times { |i| output << i }
          end

          # This stage has demand disabled - won't block on demand
          consumer :no_demand_stage, demand_mode: :disabled do |item, output|
            output << item
          end

          consumer :sink do |item|
            mutex.synchronize { results << item }
          end
        end
      end

      task.new.run

      expect(results.size).to eq(20)
    end
  end

  describe 'global configuration' do
    around do |example|
      # Save original settings
      original = Minigun.configuration.demand_enabled

      example.run

      # Restore
      Minigun.configuration.demand_enabled = original
    end

    it 'respects global demand_enabled setting' do
      Minigun.configuration.demand_enabled = true

      results = []
      mutex = Mutex.new

      task = Class.new do
        include Minigun::DSL

        pipeline do # No explicit demand: true, uses global
          producer :source do |output|
            10.times { |i| output << i }
          end

          consumer :sink do |item|
            mutex.synchronize { results << item }
          end
        end
      end

      task.new.run

      expect(results.size).to eq(10)
    end
  end

  describe 'pipeline completion' do
    it 'processes all items and completes successfully with demand' do
      results = []
      mutex = Mutex.new

      task = Class.new do
        include Minigun::DSL

        pipeline demand: true do
          producer :source do |output|
            5.times { |i| output << i }
          end

          consumer :sink do |item|
            mutex.synchronize { results << item }
          end
        end
      end

      task.new.run

      # All items should be processed
      expect(results.size).to eq(5)
      expect(results.sort).to eq([0, 1, 2, 3, 4])
    end
  end

  describe 'edge cases' do
    it 'handles empty producer' do
      results = []
      mutex = Mutex.new

      task = Class.new do
        include Minigun::DSL

        pipeline demand: true do
          producer :source do |_output|
            # Empty - no items
          end

          consumer :sink do |item|
            mutex.synchronize { results << item }
          end
        end
      end

      task.new.run

      expect(results).to be_empty
    end

    it 'handles single item' do
      results = []
      mutex = Mutex.new

      task = Class.new do
        include Minigun::DSL

        pipeline demand: true do
          producer :source do |output|
            output << :single
          end

          consumer :sink do |item|
            mutex.synchronize { results << item }
          end
        end
      end

      task.new.run

      expect(results).to eq([:single])
    end

    it 'handles filtering (some items not passed)' do
      results = []
      mutex = Mutex.new

      task = Class.new do
        include Minigun::DSL

        pipeline demand: true do
          producer :source do |output|
            20.times { |i| output << i }
          end

          # Only pass even numbers
          consumer :filter do |item, output|
            output << item if item.even?
          end

          consumer :sink do |item|
            mutex.synchronize { results << item }
          end
        end
      end

      task.new.run

      expect(results.size).to eq(10) # 0,2,4,6,8,10,12,14,16,18
      expect(results.sort).to eq([0, 2, 4, 6, 8, 10, 12, 14, 16, 18])
    end

    it 'handles amplification (one input produces multiple outputs)' do
      results = []
      mutex = Mutex.new

      task = Class.new do
        include Minigun::DSL

        pipeline demand: true do
          producer :source do |output|
            5.times { |i| output << i }
          end

          # Each item produces 3 outputs
          consumer :amplify do |item, output|
            output << "#{item}a"
            output << "#{item}b"
            output << "#{item}c"
          end

          consumer :sink do |item|
            mutex.synchronize { results << item }
          end
        end
      end

      task.new.run

      expect(results.size).to eq(15) # 5 items * 3 outputs each
    end

    it 'handles very small demand buffers' do
      results = []
      mutex = Mutex.new

      task = Class.new do
        include Minigun::DSL

        pipeline demand: true do
          producer :source do |output|
            10.times { |i| output << i }
          end

          # Very small buffer: request 2 when at 1, max 2
          consumer :sink, min_demand: 1, max_demand: 2 do |item|
            mutex.synchronize { results << item }
          end
        end
      end

      task.new.run

      expect(results.size).to eq(10)
    end

    it 'handles fan-out with demand' do
      results_a = []
      results_b = []
      mutex = Mutex.new

      task = Class.new do
        include Minigun::DSL

        pipeline demand: true do
          producer :source, to: %i[path_a path_b] do |output|
            5.times { |i| output << i }
          end

          consumer :path_a do |item|
            mutex.synchronize { results_a << item }
          end

          consumer :path_b do |item|
            mutex.synchronize { results_b << item }
          end
        end
      end

      task.new.run

      expect(results_a.size).to eq(5)
      expect(results_b.size).to eq(5)
    end

    it 'handles fan-in with demand' do
      results = []
      mutex = Mutex.new

      task = Class.new do
        include Minigun::DSL

        pipeline demand: true do
          producer :source_a, to: :merge do |output|
            3.times { |i| output << "a#{i}" }
          end

          producer :source_b, to: :merge do |output|
            3.times { |i| output << "b#{i}" }
          end

          consumer :merge do |item|
            mutex.synchronize { results << item }
          end
        end
      end

      task.new.run

      expect(results.size).to eq(6)
    end

    it 'handles explicit routing with demand' do
      high = []
      low = []
      mutex = Mutex.new

      task = Class.new do
        include Minigun::DSL

        pipeline demand: true do
          producer :source do |output|
            10.times { |i| output << i }
          end

          consumer :router, to: %i[high low] do |item, output|
            if item >= 5
              output.to(:high) << item
            else
              output.to(:low) << item
            end
          end

          consumer :high do |item|
            mutex.synchronize { high << item }
          end

          consumer :low do |item|
            mutex.synchronize { low << item }
          end
        end
      end

      task.new.run

      expect(high.sort).to eq([5, 6, 7, 8, 9])
      expect(low.sort).to eq([0, 1, 2, 3, 4])
    end

    it 'handles produce_each with demand' do
      results = []
      mutex = Mutex.new

      task = Class.new do
        include Minigun::DSL

        pipeline demand: true do
          produce_each :source, (0...20)

          consumer :sink do |item|
            mutex.synchronize { results << item }
          end
        end
      end

      task.new.run

      expect(results.size).to eq(20)
      expect(results.sort).to eq((0...20).to_a)
    end

    it 'handles batch with demand' do
      batches = []
      mutex = Mutex.new

      task = Class.new do
        include Minigun::DSL

        pipeline demand: true do
          producer :source do |output|
            25.times { |i| output << i }
          end

          batch :batcher, max_size: 5

          consumer :sink do |batch|
            mutex.synchronize { batches << batch.dup }
          end
        end
      end

      task.new.run

      expect(batches.size).to eq(5) # 25 items / 5 per batch
      expect(batches.flatten.size).to eq(25)
    end
  end
end
