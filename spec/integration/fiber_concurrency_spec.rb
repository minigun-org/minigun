# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Fiber concurrency', skip: !Minigun::Platform.fibers? do
  describe 'pool_timeout option' do
    it 'cancels fibers when timeout is reached' do
      processed = []
      mutex = Mutex.new

      pipeline_class = Class.new do
        include Minigun::DSL

        pipeline do
          produce_each :numbers, (1..10).to_a

          # Very short timeout, slow processing
          in_fibers(5, pool_timeout: 0.1) do
            consumer :slow_process do |n, output|
              sleep 0.5 # Will timeout
              mutex.synchronize { processed << n }
              output << n
            end
          end

          consumer :sink do |_n|
            # Just consume
          end
        end

        define_method(:processed) { processed }
        define_method(:mutex) { mutex }
      end

      instance = pipeline_class.new
      expect { instance.perform }.not_to raise_error
      # Should have processed fewer items due to timeout
      expect(instance.processed.size).to be < 10
    end

    it 'completes normally when within timeout' do
      processed = []
      mutex = Mutex.new

      pipeline_class = Class.new do
        include Minigun::DSL

        pipeline do
          produce_each :numbers, (1..5).to_a

          # Long timeout, fast processing
          in_fibers(5, pool_timeout: 10) do
            consumer :fast_process do |n, output|
              sleep 0.01
              mutex.synchronize { processed << n }
              output << n
            end
          end

          consumer :sink do |_n|
            # Just consume
          end
        end

        define_method(:processed) { processed }
        define_method(:mutex) { mutex }
      end

      instance = pipeline_class.new
      instance.perform
      expect(instance.processed.size).to eq(5)
    end
  end

  describe 'in_fibers execution' do
    it 'processes items concurrently with fibers' do
      results = []
      mutex = Mutex.new

      pipeline_class = Class.new do
        include Minigun::DSL

        pipeline do
          produce_each :numbers, (1..10).to_a

          in_fibers(5) do
            consumer :process do |n, output|
              mutex.synchronize { results << n }
              output << (n * 2)
            end
          end

          consumer :collect do |n|
            mutex.synchronize { results << "done:#{n}" }
          end
        end

        define_method(:results) { results }
        define_method(:mutex) { mutex }
      end

      pipeline_class.new.perform
      expect(results.count { |r| r.is_a?(Integer) }).to eq(10)
      expect(results.count { |r| r.to_s.start_with?('done:') }).to eq(10)
    end

    it 'respects fiber pool size limit' do
      max_concurrent = 0
      current_concurrent = 0
      mutex = Mutex.new

      pipeline_class = Class.new do
        include Minigun::DSL

        pipeline do
          produce_each :numbers, (1..20).to_a

          in_fibers(3) do
            consumer :slow_process do |n, output|
              mutex.synchronize do
                current_concurrent += 1
                max_concurrent = [max_concurrent, current_concurrent].max
              end
              sleep 0.01 # Simulate I/O
              mutex.synchronize { current_concurrent -= 1 }
              output << n
            end
          end

          consumer :sink do |_n|
            # Just consume
          end
        end

        define_method(:max_concurrent) { max_concurrent }
        define_method(:current_concurrent) { current_concurrent }
        define_method(:mutex) { mutex }
      end

      instance = pipeline_class.new
      instance.perform
      expect(instance.max_concurrent).to be <= 3
    end

    it 'handles errors gracefully without crashing pipeline' do
      processed = []
      mutex = Mutex.new

      pipeline_class = Class.new do
        include Minigun::DSL

        pipeline do
          produce_each :numbers, (1..10).to_a

          in_fibers(5) do
            consumer :error_prone do |n, output|
              raise "boom at #{n}" if n == 5

              mutex.synchronize { processed << n }
              output << n
            end
          end

          consumer :sink do |_n|
            # Just consume
          end
        end

        define_method(:processed) { processed }
        define_method(:mutex) { mutex }
      end

      instance = pipeline_class.new
      expect { instance.perform }.not_to raise_error
      # 9 items processed (1-4, 6-10), item 5 errored
      expect(instance.processed.size).to eq(9)
      expect(instance.processed).not_to include(5)
    end

    it 'works with multiple fiber stages in sequence' do
      results = []
      mutex = Mutex.new

      pipeline_class = Class.new do
        include Minigun::DSL

        pipeline do
          produce_each :numbers, (1..5).to_a

          in_fibers(3) do
            consumer :double do |n, output|
              output << (n * 2)
            end
          end

          in_fibers(3) do
            consumer :add_ten do |n, output|
              output << (n + 10)
            end
          end

          consumer :collect do |n|
            mutex.synchronize { results << n }
          end
        end

        define_method(:results) { results }
        define_method(:mutex) { mutex }
      end

      pipeline_class.new.perform
      # Input: 1,2,3,4,5 -> double: 2,4,6,8,10 -> add_ten: 12,14,16,18,20
      expect(results.sort).to eq([12, 14, 16, 18, 20])
    end

    it 'works alongside thread stages' do
      fiber_results = []
      thread_results = []
      mutex = Mutex.new

      pipeline_class = Class.new do
        include Minigun::DSL

        pipeline do
          produce_each :numbers, (1..6).to_a

          in_fibers(3) do
            consumer :fiber_stage do |n, output|
              mutex.synchronize { fiber_results << n }
              output << (n * 2)
            end
          end

          in_threads(2) do
            consumer :thread_stage do |n, output|
              mutex.synchronize { thread_results << n }
              output << n
            end
          end

          consumer :sink do |_n|
            # Just consume
          end
        end

        define_method(:fiber_results) { fiber_results }
        define_method(:thread_results) { thread_results }
        define_method(:mutex) { mutex }
      end

      instance = pipeline_class.new
      instance.perform
      expect(instance.fiber_results.size).to eq(6)
      expect(instance.thread_results.size).to eq(6)
    end

    it 'runs fibers in the same thread (cooperative concurrency)' do
      thread_ids = []
      mutex = Mutex.new
      main_thread_id = Thread.current.object_id

      pipeline_class = Class.new do
        include Minigun::DSL

        pipeline do
          produce_each :numbers, (1..5).to_a

          in_fibers(5) do
            consumer :capture_thread do |n, output|
              mutex.synchronize { thread_ids << Thread.current.object_id }
              output << n
            end
          end

          consumer :sink do |_n|
            # Just consume
          end
        end

        define_method(:thread_ids) { thread_ids }
        define_method(:mutex) { mutex }
        define_method(:main_thread_id) { main_thread_id }
      end

      instance = pipeline_class.new
      instance.perform

      # All fibers should run in a single thread (the worker thread)
      # They won't be in main_thread_id (they run in a worker thread)
      # but all should be in the SAME thread
      expect(instance.thread_ids.uniq.size).to eq(1)
    end
  end
end
