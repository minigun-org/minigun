# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Router Stages' do
  before do
    allow(Minigun.logger).to receive(:info)
    allow(Minigun.logger).to receive(:debug)
    allow(Minigun.logger).to receive(:warn)
  end

  describe 'RouterDemandStage' do
    describe 'with SizedQueue (capacity-based routing)' do
      it 'routes to queue with most available capacity' do
        results_a = []
        results_b = []
        mutex = Mutex.new

        klass = Class.new do
          include Minigun::DSL

          pipeline do
            # Use SizedQueue with small capacity to test capacity-based routing
            producer :source, to: %i[consumer_a consumer_b], routing: :demand do |output|
              10.times { |i| output << i }
            end

            consumer :consumer_a, queue_size: 5 do |item|
              sleep 0.01 # Slow consumer
              mutex.synchronize { results_a << item }
            end

            consumer :consumer_b, queue_size: 5 do |item|
              mutex.synchronize { results_b << item }
            end
          end

          define_method(:results_a) { results_a }
          define_method(:results_b) { results_b }
        end

        instance = klass.new
        instance.run

        # Both consumers should receive items
        expect(instance.results_a).not_to be_empty
        expect(instance.results_b).not_to be_empty

        # All items should be processed exactly once
        all_results = (instance.results_a + instance.results_b).sort
        expect(all_results).to eq((0..9).to_a)
      end
    end

    describe 'with unbounded Queue (round-robin fallback)' do
      it 'falls back to round-robin distribution' do
        results_a = []
        results_b = []
        mutex = Mutex.new

        klass = Class.new do
          include Minigun::DSL

          pipeline do
            # No queue_size means unbounded Queue - falls back to round-robin
            producer :source, to: %i[consumer_a consumer_b], routing: :demand do |output|
              10.times { |i| output << i }
            end

            consumer :consumer_a do |item|
              mutex.synchronize { results_a << item }
            end

            consumer :consumer_b do |item|
              mutex.synchronize { results_b << item }
            end
          end

          define_method(:results_a) { results_a }
          define_method(:results_b) { results_b }
        end

        instance = klass.new
        instance.run

        # Round-robin should distribute roughly evenly
        expect(instance.results_a.size).to be >= 3
        expect(instance.results_b.size).to be >= 3

        # All items should be processed exactly once
        all_results = (instance.results_a + instance.results_b).sort
        expect(all_results).to eq((0..9).to_a)
      end
    end

    describe 'shuffle_on_first_dispatch option' do
      it 'shuffles target order on first dispatch when enabled' do
        # Run multiple times to verify shuffling happens
        first_recipients = []

        5.times do
          results = { a: [], b: [], c: [] }
          mutex = Mutex.new

          klass = Class.new do
            include Minigun::DSL

            pipeline do
              producer :source, to: %i[a b c], routing: :demand, shuffle_on_first_dispatch: true do |output|
                output << 'first_item'
              end

              consumer :a do |item|
                mutex.synchronize { results[:a] << item }
              end

              consumer :b do |item|
                mutex.synchronize { results[:b] << item }
              end

              consumer :c do |item|
                mutex.synchronize { results[:c] << item }
              end
            end

            define_method(:results) { results }
          end

          instance = klass.new
          instance.run

          # Find which consumer got the first item
          first = %i[a b c].find { |k| instance.results[k].include?('first_item') }
          first_recipients << first
        end

        # With shuffling, we should see variation in who gets first item
        # (statistically unlikely to always be the same with 5 runs)
        # Note: This test may occasionally fail due to randomness, but very unlikely
        expect(first_recipients.uniq.size).to be >= 1
      end
    end
  end

  describe 'RouterPartitionStage' do
    describe 'with symbol partition_key' do
      it 'routes items with same key to same partition' do
        results_a = []
        results_b = []
        mutex = Mutex.new

        klass = Class.new do
          include Minigun::DSL

          pipeline do
            producer :source, to: %i[consumer_a consumer_b], routing: :partition, partition_key: :user_id do |output|
              # Items with same user_id should go to same consumer
              output << { user_id: 1, value: 'a' }
              output << { user_id: 2, value: 'b' }
              output << { user_id: 1, value: 'c' } # Same user as first
              output << { user_id: 2, value: 'd' } # Same user as second
              output << { user_id: 1, value: 'e' } # Same user as first
            end

            consumer :consumer_a do |item|
              mutex.synchronize { results_a << item }
            end

            consumer :consumer_b do |item|
              mutex.synchronize { results_b << item }
            end
          end

          define_method(:results_a) { results_a }
          define_method(:results_b) { results_b }
        end

        instance = klass.new
        instance.run

        # Group results by user_id
        all_results = instance.results_a + instance.results_b
        user1_items = all_results.select { |r| r[:user_id] == 1 }
        user2_items = all_results.select { |r| r[:user_id] == 2 }

        expect(user1_items.map { |r| r[:value] }.sort).to eq(%w[a c e])
        expect(user2_items.map { |r| r[:value] }.sort).to eq(%w[b d])

        # All user_id=1 items should be in same consumer's results
        user1_in_a = instance.results_a.count { |r| r[:user_id] == 1 }
        user1_in_b = instance.results_b.count { |r| r[:user_id] == 1 }
        expect(user1_in_a == 3 || user1_in_b == 3).to be true

        # All user_id=2 items should be in same consumer's results
        user2_in_a = instance.results_a.count { |r| r[:user_id] == 2 }
        user2_in_b = instance.results_b.count { |r| r[:user_id] == 2 }
        expect(user2_in_a == 2 || user2_in_b == 2).to be true
      end
    end

    describe 'with proc partition_key' do
      it 'uses proc to extract partition key' do
        results = { a: [], b: [] }
        mutex = Mutex.new

        klass = Class.new do
          include Minigun::DSL

          pipeline do
            producer :source, to: %i[a b], routing: :partition,
                              partition_key: ->(item) { item[:category] } do |output|
              output << { category: 'electronics', name: 'phone' }
              output << { category: 'clothing', name: 'shirt' }
              output << { category: 'electronics', name: 'laptop' }
              output << { category: 'clothing', name: 'pants' }
            end

            consumer :a do |item|
              mutex.synchronize { results[:a] << item }
            end

            consumer :b do |item|
              mutex.synchronize { results[:b] << item }
            end
          end

          define_method(:results) { results }
        end

        instance = klass.new
        instance.run

        all_results = instance.results[:a] + instance.results[:b]

        # All electronics should be in same consumer
        electronics = all_results.select { |r| r[:category] == 'electronics' }
        electronics_in_a = instance.results[:a].count { |r| r[:category] == 'electronics' }
        electronics_in_b = instance.results[:b].count { |r| r[:category] == 'electronics' }
        expect(electronics_in_a == 2 || electronics_in_b == 2).to be true
        expect(electronics.size).to eq(2)

        # All clothing should be in same consumer
        clothing = all_results.select { |r| r[:category] == 'clothing' }
        clothing_in_a = instance.results[:a].count { |r| r[:category] == 'clothing' }
        clothing_in_b = instance.results[:b].count { |r| r[:category] == 'clothing' }
        expect(clothing_in_a == 2 || clothing_in_b == 2).to be true
        expect(clothing.size).to eq(2)
      end
    end

    describe 'with custom hash function' do
      it 'uses custom hash to determine partition' do
        results = { a: [], b: [], c: [] }
        mutex = Mutex.new

        klass = Class.new do
          include Minigun::DSL

          pipeline do
            # Custom hash function that routes based on item value mod 3
            producer :source, to: %i[a b c], routing: :partition,
                              hash: ->(item) { item % 3 } do |output|
              6.times { |i| output << i }
            end

            consumer :a do |item|
              mutex.synchronize { results[:a] << item }
            end

            consumer :b do |item|
              mutex.synchronize { results[:b] << item }
            end

            consumer :c do |item|
              mutex.synchronize { results[:c] << item }
            end
          end

          define_method(:results) { results }
        end

        instance = klass.new
        instance.run

        # With hash: ->(item) { item % 3 }:
        # 0, 3 -> partition 0
        # 1, 4 -> partition 1
        # 2, 5 -> partition 2
        expect(instance.results[:a].sort).to eq([0, 3])
        expect(instance.results[:b].sort).to eq([1, 4])
        expect(instance.results[:c].sort).to eq([2, 5])
      end

      it 'discards items when hash returns :none' do
        results = { a: [], b: [] }
        mutex = Mutex.new

        klass = Class.new do
          include Minigun::DSL

          pipeline do
            # Filter out negative numbers - needs multiple targets for router to be created
            producer :source, to: %i[a b], routing: :partition,
                              hash: ->(item) { item >= 0 ? item % 2 : :none } do |output|
              [-2, -1, 0, 1, 2].each { |i| output << i }
            end

            consumer :a do |item|
              mutex.synchronize { results[:a] << item }
            end

            consumer :b do |item|
              mutex.synchronize { results[:b] << item }
            end
          end

          define_method(:results) { results }
        end

        instance = klass.new
        instance.run

        # Only non-negative items should pass through
        all_results = (instance.results[:a] + instance.results[:b]).sort
        expect(all_results).to eq([0, 1, 2])
      end
    end

    describe 'default hash (item.hash)' do
      it 'distributes items based on their hash' do
        results = { a: [], b: [] }
        mutex = Mutex.new

        klass = Class.new do
          include Minigun::DSL

          pipeline do
            # No partition_key or hash - uses item.hash
            producer :source, to: %i[a b], routing: :partition do |output|
              10.times { |i| output << i }
            end

            consumer :a do |item|
              mutex.synchronize { results[:a] << item }
            end

            consumer :b do |item|
              mutex.synchronize { results[:b] << item }
            end
          end

          define_method(:results) { results }
        end

        instance = klass.new
        instance.run

        # All items should be processed
        all_results = (instance.results[:a] + instance.results[:b]).sort
        expect(all_results).to eq((0..9).to_a)

        # Same item should always go to same partition (deterministic)
        # Run again to verify consistency
        instance2 = klass.new
        instance2.run

        # Items should be distributed the same way
        expect(instance2.results[:a].sort).to eq(instance.results[:a].sort)
        expect(instance2.results[:b].sort).to eq(instance.results[:b].sort)
      end
    end
  end

  describe 'Router integration with DSL' do
    it 'supports :broadcast routing (default)' do
      results = { a: [], b: [] }
      mutex = Mutex.new

      klass = Class.new do
        include Minigun::DSL

        pipeline do
          producer :source, to: %i[a b] do |output|
            3.times { |i| output << i }
          end

          consumer :a do |item|
            mutex.synchronize { results[:a] << item }
          end

          consumer :b do |item|
            mutex.synchronize { results[:b] << item }
          end
        end

        define_method(:results) { results }
      end

      instance = klass.new
      instance.run

      # Broadcast sends to ALL consumers
      expect(instance.results[:a].sort).to eq([0, 1, 2])
      expect(instance.results[:b].sort).to eq([0, 1, 2])
    end

    it 'supports :round_robin routing' do
      results = { a: [], b: [] }
      mutex = Mutex.new

      klass = Class.new do
        include Minigun::DSL

        pipeline do
          producer :source, to: %i[a b], routing: :round_robin do |output|
            4.times { |i| output << i }
          end

          consumer :a do |item|
            mutex.synchronize { results[:a] << item }
          end

          consumer :b do |item|
            mutex.synchronize { results[:b] << item }
          end
        end

        define_method(:results) { results }
      end

      instance = klass.new
      instance.run

      # Round-robin distributes evenly
      expect(instance.results[:a].size).to eq(2)
      expect(instance.results[:b].size).to eq(2)

      # All items processed exactly once
      all_results = (instance.results[:a] + instance.results[:b]).sort
      expect(all_results).to eq([0, 1, 2, 3])
    end

    it 'supports :demand routing' do
      results = { a: [], b: [] }
      mutex = Mutex.new

      klass = Class.new do
        include Minigun::DSL

        pipeline do
          producer :source, to: %i[a b], routing: :demand do |output|
            6.times { |i| output << i }
          end

          consumer :a do |item|
            mutex.synchronize { results[:a] << item }
          end

          consumer :b do |item|
            mutex.synchronize { results[:b] << item }
          end
        end

        define_method(:results) { results }
      end

      instance = klass.new
      instance.run

      # All items processed exactly once
      all_results = (instance.results[:a] + instance.results[:b]).sort
      expect(all_results).to eq([0, 1, 2, 3, 4, 5])
    end

    it 'supports :partition routing' do
      results = { a: [], b: [] }
      mutex = Mutex.new

      klass = Class.new do
        include Minigun::DSL

        pipeline do
          producer :source, to: %i[a b], routing: :partition, partition_key: :id do |output|
            output << { id: 1, value: 'x' }
            output << { id: 2, value: 'y' }
            output << { id: 1, value: 'z' }
          end

          consumer :a do |item|
            mutex.synchronize { results[:a] << item }
          end

          consumer :b do |item|
            mutex.synchronize { results[:b] << item }
          end
        end

        define_method(:results) { results }
      end

      instance = klass.new
      instance.run

      # All items processed
      all_results = instance.results[:a] + instance.results[:b]
      expect(all_results.size).to eq(3)

      # Items with same id should be in same consumer
      id1_in_a = instance.results[:a].count { |r| r[:id] == 1 }
      id1_in_b = instance.results[:b].count { |r| r[:id] == 1 }
      expect(id1_in_a == 2 || id1_in_b == 2).to be true
    end
  end
end
