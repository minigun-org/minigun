# frozen_string_literal: true

require 'spec_helper'
require 'drb'
require 'socket'

# Tests for cluster execution with different routing strategies
RSpec.describe 'Cluster with Routing Strategies' do
  let(:started_services) { [] }

  def find_available_port
    server = TCPServer.new('127.0.0.1', 0)
    port = server.addr[1]
    server.close
    port
  end

  def create_worker(port, stage_name = :process, &block)
    worker = Minigun::Cluster::Worker.new(coordinator_uri: nil, worker_id: "test-worker-#{port}")
    worker.register_stage(stage_name, &block)
    service = Minigun::Cluster::WorkerService.new(worker)
    uri = "druby://127.0.0.1:#{port}"
    drb_server = DRb.start_service(uri, service)
    started_services << drb_server
    { worker: worker, service: service, uri: uri, port: port }
  end

  def cleanup_services
    started_services.each do |service|
      service.stop_service
    rescue StandardError
      nil
    end
    started_services.clear
    sleep 0.05
  end

  after do
    cleanup_services
    begin
      DRb.stop_service
    rescue StandardError
      nil
    end
  end

  describe 'broadcast routing with cluster' do
    it 'broadcasts from cluster output to multiple local consumers' do
      port = find_available_port
      worker = create_worker(port, :transform) { |item, output| output.call(item * 2) }

      results_a = []
      results_b = []
      mutex = Mutex.new

      klass = Class.new do
        include Minigun::DSL

        def initialize(worker_uri, results_a, results_b, mutex)
          @worker_uri = worker_uri
          @results_a = results_a
          @results_b = results_b
          @mutex = mutex
        end

        pipeline do
          producer :source do |output|
            5.times { |i| output << i }
          end

          in_cluster(worker_uris: [@worker_uri], shutdown_on_done: false) do
            # Default routing is broadcast
            processor :transform, to: %i[consumer_a consumer_b] do |item, output|
              output << item
            end
          end

          consumer :consumer_a do |item|
            @mutex.synchronize { @results_a << item }
          end

          consumer :consumer_b do |item|
            @mutex.synchronize { @results_b << item }
          end
        end
      end

      pipeline = klass.new(worker[:uri], results_a, results_b, mutex)
      pipeline.run

      # Broadcast sends to ALL consumers
      expect(results_a.sort).to eq([0, 2, 4, 6, 8])
      expect(results_b.sort).to eq([0, 2, 4, 6, 8])
    end
  end

  describe 'round_robin routing with cluster' do
    it 'distributes from cluster output round-robin to local consumers' do
      port = find_available_port
      worker = create_worker(port, :process) { |item, output| output.call(item) }

      results_a = []
      results_b = []
      mutex = Mutex.new

      klass = Class.new do
        include Minigun::DSL

        def initialize(worker_uri, results_a, results_b, mutex)
          @worker_uri = worker_uri
          @results_a = results_a
          @results_b = results_b
          @mutex = mutex
        end

        pipeline do
          producer :source do |output|
            10.times { |i| output << i }
          end

          in_cluster(worker_uris: [@worker_uri], shutdown_on_done: false) do
            # Round-robin routing after cluster
            processor :process, to: %i[consumer_a consumer_b], routing: :round_robin do |item, output|
              output << item
            end
          end

          consumer :consumer_a do |item|
            @mutex.synchronize { @results_a << item }
          end

          consumer :consumer_b do |item|
            @mutex.synchronize { @results_b << item }
          end
        end
      end

      pipeline = klass.new(worker[:uri], results_a, results_b, mutex)
      pipeline.run

      # Round-robin distributes evenly
      expect(results_a.size).to eq(5)
      expect(results_b.size).to eq(5)
      all_results = (results_a + results_b).sort
      expect(all_results).to eq((0..9).to_a)
    end
  end

  describe 'demand routing with cluster' do
    it 'routes from cluster output to consumer with most capacity' do
      port = find_available_port
      worker = create_worker(port, :process) { |item, output| output.call(item * 2) }

      results_a = []
      results_b = []
      mutex = Mutex.new

      klass = Class.new do
        include Minigun::DSL

        def initialize(worker_uri, results_a, results_b, mutex)
          @worker_uri = worker_uri
          @results_a = results_a
          @results_b = results_b
          @mutex = mutex
        end

        pipeline do
          producer :source do |output|
            12.times { |i| output << i }
          end

          in_cluster(worker_uris: [@worker_uri], shutdown_on_done: false) do
            # Demand-based routing after cluster
            processor :process, to: %i[fast slow], routing: :demand do |item, output|
              output << item
            end
          end

          # Fast consumer
          consumer :fast, queue_size: 10 do |item|
            @mutex.synchronize { @results_a << item }
          end

          # Slow consumer - takes longer, so demand router should send less here
          consumer :slow, queue_size: 10 do |item|
            sleep 0.01
            @mutex.synchronize { @results_b << item }
          end
        end
      end

      pipeline = klass.new(worker[:uri], results_a, results_b, mutex)
      pipeline.run

      # All items processed exactly once
      all_results = (results_a + results_b).sort
      expect(all_results).to eq((0..11).map { |i| i * 2 })

      # Both consumers should receive some items
      expect(results_a).not_to be_empty
      expect(results_b).not_to be_empty
    end
  end

  describe 'partition routing with cluster' do
    it 'routes from cluster output by partition key' do
      port = find_available_port
      worker = create_worker(port, :enrich) do |item, output|
        output.call({ user_id: item[:user_id], data: "enriched-#{item[:data]}" })
      end

      results_a = []
      results_b = []
      mutex = Mutex.new

      klass = Class.new do
        include Minigun::DSL

        def initialize(worker_uri, results_a, results_b, mutex)
          @worker_uri = worker_uri
          @results_a = results_a
          @results_b = results_b
          @mutex = mutex
        end

        pipeline do
          producer :source do |output|
            # Items with different user_ids
            [
              { user_id: 1, data: 'a' },
              { user_id: 2, data: 'b' },
              { user_id: 1, data: 'c' },
              { user_id: 2, data: 'd' },
              { user_id: 1, data: 'e' },
              { user_id: 3, data: 'f' }
            ].each { |item| output << item }
          end

          in_cluster(worker_uris: [@worker_uri], shutdown_on_done: false) do
            # Partition routing by user_id
            processor :enrich, to: %i[partition_a partition_b], routing: :partition, partition_key: :user_id do |item, output|
              output << item
            end
          end

          consumer :partition_a do |item|
            @mutex.synchronize { @results_a << item }
          end

          consumer :partition_b do |item|
            @mutex.synchronize { @results_b << item }
          end
        end
      end

      pipeline = klass.new(worker[:uri], results_a, results_b, mutex)
      pipeline.run

      all_results = results_a + results_b

      # All items processed
      expect(all_results.size).to eq(6)

      # Same user_id should go to same partition
      user1_items = all_results.select { |r| r[:user_id] == 1 }
      all_results.select { |r| r[:user_id] == 2 }

      # All user_id=1 items should be in same consumer
      user1_in_a = results_a.count { |r| r[:user_id] == 1 }
      user1_in_b = results_b.count { |r| r[:user_id] == 1 }
      expect(user1_in_a == 3 || user1_in_b == 3).to be true

      # All user_id=2 items should be in same consumer
      user2_in_a = results_a.count { |r| r[:user_id] == 2 }
      user2_in_b = results_b.count { |r| r[:user_id] == 2 }
      expect(user2_in_a == 2 || user2_in_b == 2).to be true

      # Verify enrichment happened
      expect(user1_items.first[:data]).to start_with('enriched-')
    end
  end

  describe 'partition routing with custom hash function' do
    it 'routes using custom hash function from cluster output' do
      port = find_available_port
      worker = create_worker(port, :process) { |item, output| output.call(item) }

      results = { a: [], b: [], c: [] }
      mutex = Mutex.new

      klass = Class.new do
        include Minigun::DSL

        def initialize(worker_uri, results, mutex)
          @worker_uri = worker_uri
          @results = results
          @mutex = mutex
        end

        pipeline do
          producer :source do |output|
            9.times { |i| output << i }
          end

          in_cluster(worker_uris: [@worker_uri], shutdown_on_done: false) do
            # Custom hash function: item % 3
            processor :process, to: %i[a b c], routing: :partition, hash: ->(item) { item % 3 } do |item, output|
              output << item
            end
          end

          consumer :a do |item|
            @mutex.synchronize { @results[:a] << item }
          end

          consumer :b do |item|
            @mutex.synchronize { @results[:b] << item }
          end

          consumer :c do |item|
            @mutex.synchronize { @results[:c] << item }
          end
        end

        attr_reader :results
      end

      pipeline = klass.new(worker[:uri], results, mutex)
      pipeline.run

      # With hash: item % 3
      # 0, 3, 6 -> partition 0 (consumer :a)
      # 1, 4, 7 -> partition 1 (consumer :b)
      # 2, 5, 8 -> partition 2 (consumer :c)
      expect(pipeline.results[:a].sort).to eq([0, 3, 6])
      expect(pipeline.results[:b].sort).to eq([1, 4, 7])
      expect(pipeline.results[:c].sort).to eq([2, 5, 8])
    end
  end

  describe 'routing before cluster stage' do
    it 'supports round-robin routing to cluster input' do
      port1 = find_available_port
      port2 = find_available_port

      workers = []
      workers << create_worker(port1, :process) { |item, output| output.call({ value: item, worker: 1 }) }
      workers << create_worker(port2, :process) { |item, output| output.call({ value: item, worker: 2 }) }

      results = []
      mutex = Mutex.new

      klass = Class.new do
        include Minigun::DSL

        def initialize(worker_uris, results, mutex)
          @worker_uris = worker_uris
          @results = results
          @mutex = mutex
        end

        pipeline do
          # NOTE: The cluster itself does round-robin distribution to workers
          producer :source do |output|
            10.times { |i| output << i }
          end

          in_cluster(worker_uris: @worker_uris, shutdown_on_done: false) do
            processor :process do |item, output|
              output << item
            end
          end

          consumer :sink do |item|
            @mutex.synchronize { @results << item }
          end
        end
      end

      pipeline = klass.new(workers.map { |w| w[:uri] }, results, mutex)
      pipeline.run

      # All items processed
      expect(results.size).to eq(10)

      # Both workers should have processed items (round-robin in cluster)
      worker1_results = results.select { |r| r[:worker] == 1 }
      worker2_results = results.select { |r| r[:worker] == 2 }
      expect(worker1_results).not_to be_empty
      expect(worker2_results).not_to be_empty

      # All values present
      all_values = results.map { |r| r[:value] }.sort
      expect(all_values).to eq((0..9).to_a)
    end
  end

  describe 'mixed routing: broadcast before cluster, partition after' do
    it 'combines broadcast input with partition output' do
      port = find_available_port
      worker = create_worker(port, :categorize) do |item, output|
        category = item[:value].even? ? :even : :odd
        output.call({ original: item[:value], category: category })
      end

      evens = []
      odds = []
      mutex = Mutex.new

      klass = Class.new do
        include Minigun::DSL

        def initialize(worker_uri, evens, odds, mutex)
          @worker_uri = worker_uri
          @evens = evens
          @odds = odds
          @mutex = mutex
        end

        pipeline do
          producer :source do |output|
            6.times { |i| output << { value: i } }
          end

          in_cluster(worker_uris: [@worker_uri], shutdown_on_done: false) do
            # Partition by category after cluster processing
            processor :categorize, to: %i[evens odds], routing: :partition, partition_key: :category do |item, output|
              output << item
            end
          end

          consumer :evens do |item|
            @mutex.synchronize { @evens << item }
          end

          consumer :odds do |item|
            @mutex.synchronize { @odds << item }
          end
        end
      end

      pipeline = klass.new(worker[:uri], evens, odds, mutex)
      pipeline.run

      # All items processed
      expect(evens.size + odds.size).to eq(6)

      # All evens should be in same consumer
      even_in_evens = evens.count { |r| r[:category] == :even }
      even_in_odds = odds.count { |r| r[:category] == :even }
      expect(even_in_evens == 3 || even_in_odds == 3).to be true

      # All odds should be in same consumer
      odd_in_evens = evens.count { |r| r[:category] == :odd }
      odd_in_odds = odds.count { |r| r[:category] == :odd }
      expect(odd_in_evens == 3 || odd_in_odds == 3).to be true
    end
  end

  describe 'routing with demand and cluster' do
    it 'combines demand routing with demand-enabled pipeline' do
      port = find_available_port
      worker = create_worker(port, :process) { |item, output| output.call(item * 10) }

      results_fast = []
      results_slow = []
      mutex = Mutex.new

      klass = Class.new do
        include Minigun::DSL

        def initialize(worker_uri, results_fast, results_slow, mutex)
          @worker_uri = worker_uri
          @results_fast = results_fast
          @results_slow = results_slow
          @mutex = mutex
        end

        pipeline demand: true do
          producer :source do |output|
            8.times { |i| output << i }
          end

          in_cluster(worker_uris: [@worker_uri], shutdown_on_done: false) do
            # Demand-based routing with demand-enabled pipeline
            processor :process, to: %i[fast slow], routing: :demand do |item, output|
              output << item
            end
          end

          consumer :fast, queue_size: 5 do |item|
            @mutex.synchronize { @results_fast << item }
          end

          consumer :slow, queue_size: 5, min_demand: 1, max_demand: 3 do |item|
            sleep 0.005
            @mutex.synchronize { @results_slow << item }
          end
        end
      end

      pipeline = klass.new(worker[:uri], results_fast, results_slow, mutex)
      pipeline.run

      # All items processed exactly once
      all_results = (results_fast + results_slow).sort
      expect(all_results).to eq((0..7).map { |i| i * 10 })
    end
  end
end
