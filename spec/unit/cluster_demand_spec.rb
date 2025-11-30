# frozen_string_literal: true

require 'spec_helper'
require 'drb'
require 'socket'

# Tests for cluster execution with demand (min/max) settings
RSpec.describe 'Cluster with Demand Settings' do
  # Test harness for cluster workers
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

  describe 'basic cluster with demand enabled' do
    it 'processes items with demand: true pipeline option' do
      port1 = find_available_port
      port2 = find_available_port

      workers = []
      workers << create_worker(port1, :compute) { |item, output| output.call(item * 2) }
      workers << create_worker(port2, :compute) { |item, output| output.call(item * 2) }

      results = []
      mutex = Mutex.new

      klass = Class.new do
        include Minigun::DSL

        def initialize(worker_uris, results, mutex)
          @worker_uris = worker_uris
          @results = results
          @mutex = mutex
        end

        pipeline demand: true do
          producer :source do |output|
            20.times { |i| output << i }
          end

          in_cluster(worker_uris: @worker_uris, shutdown_on_done: false) do
            processor :compute do |item, output|
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

      expect(results.size).to eq(20)
      expect(results.sort).to eq((0..19).map { |i| i * 2 })
    end

    it 'respects custom min_demand and max_demand settings' do
      port1 = find_available_port
      port2 = find_available_port

      workers = []
      workers << create_worker(port1, :process) { |item, output| output.call(item + 1) }
      workers << create_worker(port2, :process) { |item, output| output.call(item + 1) }

      results = []
      mutex = Mutex.new

      klass = Class.new do
        include Minigun::DSL

        def initialize(worker_uris, results, mutex)
          @worker_uris = worker_uris
          @results = results
          @mutex = mutex
        end

        pipeline demand: true do
          producer :source do |output|
            30.times { |i| output << i }
          end

          in_cluster(worker_uris: @worker_uris, shutdown_on_done: false) do
            processor :process do |item, output|
              output << item
            end
          end

          # Custom demand settings: smaller buffer
          consumer :sink, min_demand: 5, max_demand: 10 do |item|
            @mutex.synchronize { @results << item }
          end
        end
      end

      pipeline = klass.new(workers.map { |w| w[:uri] }, results, mutex)
      pipeline.run

      expect(results.size).to eq(30)
      expect(results.sort).to eq((1..30).to_a)
    end
  end

  describe 'cluster with demand and multiple stages' do
    it 'processes through cluster stage then local consumer with demand' do
      port = find_available_port
      worker = create_worker(port, :transform) { |item, output| output.call({ value: item, transformed: true }) }

      results = []
      mutex = Mutex.new

      klass = Class.new do
        include Minigun::DSL

        def initialize(worker_uri, results, mutex)
          @worker_uri = worker_uri
          @results = results
          @mutex = mutex
        end

        pipeline demand: true do
          producer :source, min_demand: 3, max_demand: 8 do |output|
            15.times { |i| output << i }
          end

          in_cluster(worker_uris: [@worker_uri], shutdown_on_done: false) do
            processor :transform do |item, output|
              output << item
            end
          end

          consumer :local_processor do |item, output|
            output << { value: item[:value] * 2, from: :local }
          end

          consumer :sink, min_demand: 2, max_demand: 5 do |item|
            @mutex.synchronize { @results << item }
          end
        end
      end

      pipeline = klass.new(worker[:uri], results, mutex)
      pipeline.run

      expect(results.size).to eq(15)
      results.each do |r|
        expect(r[:from]).to eq(:local)
        expect(r[:value]).to be_even
      end
    end
  end

  describe 'cluster with demand and fan-out' do
    it 'handles fan-out after cluster stage with demand' do
      port = find_available_port
      worker = create_worker(port, :double) { |item, output| output.call(item * 2) }

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

        pipeline demand: true do
          producer :source do |output|
            10.times { |i| output << i }
          end

          in_cluster(worker_uris: [@worker_uri], shutdown_on_done: false) do
            processor :double, to: %i[path_a path_b] do |item, output|
              output << item
            end
          end

          consumer :path_a do |item|
            @mutex.synchronize { @results_a << item }
          end

          consumer :path_b do |item|
            @mutex.synchronize { @results_b << item }
          end
        end
      end

      pipeline = klass.new(worker[:uri], results_a, results_b, mutex)
      pipeline.run

      # Fan-out broadcasts to both paths
      expect(results_a.size).to eq(10)
      expect(results_b.size).to eq(10)
      expect(results_a.sort).to eq((0..9).map { |i| i * 2 })
      expect(results_b.sort).to eq((0..9).map { |i| i * 2 })
    end
  end

  describe 'cluster with demand and fan-in' do
    it 'handles fan-in before cluster stage with demand' do
      port = find_available_port
      worker = create_worker(port, :cluster_stage) { |item, output| output.call({ processed: item }) }

      results = []
      mutex = Mutex.new

      klass = Class.new do
        include Minigun::DSL

        def initialize(worker_uri, results, mutex)
          @worker_uri = worker_uri
          @results = results
          @mutex = mutex
        end

        pipeline demand: true do
          producer :source_a, to: :cluster_stage do |output|
            5.times { |i| output << "a#{i}" }
          end

          producer :source_b, to: :cluster_stage do |output|
            5.times { |i| output << "b#{i}" }
          end

          in_cluster(worker_uris: [@worker_uri], shutdown_on_done: false) do
            processor :cluster_stage do |item, output|
              output << item
            end
          end

          consumer :sink do |item|
            @mutex.synchronize { @results << item }
          end
        end
      end

      pipeline = klass.new(worker[:uri], results, mutex)
      pipeline.run

      expect(results.size).to eq(10)
      processed_values = results.map { |r| r[:processed] }
      expect(processed_values).to include('a0', 'a1', 'a2', 'a3', 'a4')
      expect(processed_values).to include('b0', 'b1', 'b2', 'b3', 'b4')
    end
  end

  describe 'cluster with demand disabled on specific stages' do
    it 'allows demand_mode: :disabled on stages after cluster' do
      port = find_available_port
      worker = create_worker(port, :process) { |item, output| output.call(item * 3) }

      results = []
      mutex = Mutex.new

      klass = Class.new do
        include Minigun::DSL

        def initialize(worker_uri, results, mutex)
          @worker_uri = worker_uri
          @results = results
          @mutex = mutex
        end

        pipeline demand: true do
          producer :source do |output|
            12.times { |i| output << i }
          end

          in_cluster(worker_uris: [@worker_uri], shutdown_on_done: false) do
            processor :process do |item, output|
              output << item
            end
          end

          # Disable demand on this stage
          consumer :no_demand, demand_mode: :disabled do |item, output|
            output << item
          end

          consumer :sink do |item|
            @mutex.synchronize { @results << item }
          end
        end
      end

      pipeline = klass.new(worker[:uri], results, mutex)
      pipeline.run

      expect(results.size).to eq(12)
      expect(results.sort).to eq((0..11).map { |i| i * 3 })
    end
  end

  describe 'cluster with very small demand buffers' do
    it 'handles min_demand: 1, max_demand: 2 (tight backpressure)' do
      port = find_available_port
      worker = create_worker(port, :slow_process) do |item, output|
        sleep 0.005 # Simulate slow processing
        output.call(item * 2)
      end

      results = []
      mutex = Mutex.new

      klass = Class.new do
        include Minigun::DSL

        def initialize(worker_uri, results, mutex)
          @worker_uri = worker_uri
          @results = results
          @mutex = mutex
        end

        pipeline demand: true do
          producer :source do |output|
            10.times { |i| output << i }
          end

          in_cluster(worker_uris: [@worker_uri], shutdown_on_done: false) do
            processor :slow_process do |item, output|
              output << item
            end
          end

          # Very tight demand settings
          consumer :sink, min_demand: 1, max_demand: 2 do |item|
            @mutex.synchronize { @results << item }
          end
        end
      end

      pipeline = klass.new(worker[:uri], results, mutex)
      pipeline.run

      expect(results.size).to eq(10)
      expect(results.sort).to eq((0..9).map { |i| i * 2 })
    end
  end
end
