# frozen_string_literal: true

require 'spec_helper'
require 'tempfile'
require 'json'

RSpec.describe 'emit_to_stage' do
  describe 'basic functionality' do
    it 'routes items to explicitly named stage' do
      results = []

      klass = Class.new do
        include Minigun::DSL

        define_method(:initialize) do
          @results = results
        end

        pipeline do
          producer :gen do
            emit({ id: 1, route: :fast })
            emit({ id: 2, route: :slow })
            emit({ id: 3, route: :fast })
          end

          stage :router do |item|
            emit_to_stage(item[:route], item)
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

      expect(results.size).to eq(3)
      expect(results.select { |r| r[:stage] == :fast }.size).to eq(2)
      expect(results.select { |r| r[:stage] == :slow }.size).to eq(1)
      expect(results.map { |r| r[:id] }.sort).to eq([1, 2, 3])
    end

    it 'allows mixing emit and emit_to_stage in same stage' do
      results = []

      klass = Class.new do
        include Minigun::DSL

        define_method(:initialize) do
          @results = results
        end

        pipeline do
          producer :gen do
            emit(1)
            emit(2)
          end

          stage :router do |item|
            if item == 1
              emit(item * 10)  # Regular emit - goes to next stage via DAG
            else
              emit_to_stage(:special, item * 100)  # Targeted emit
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

      expect(results.size).to eq(2)
      expect(results).to include({ stage: :normal, value: 10 })
      expect(results).to include({ stage: :special, value: 200 })
    end

    it 'can emit_to_stage multiple times in single stage' do
      results = []

      klass = Class.new do
        include Minigun::DSL

        define_method(:initialize) do
          @results = results
        end

        pipeline do
          producer :gen do
            emit({ value: 100 })
          end

          stage :splitter do |item|
            emit_to_stage(:consumer_a, { stage: 'A', value: item[:value] })
            emit_to_stage(:consumer_b, { stage: 'B', value: item[:value] * 2 })
            emit_to_stage(:consumer_c, { stage: 'C', value: item[:value] * 3 })
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

      expect(results.size).to eq(3)
      expect(results).to include({ stage: 'A', value: 100 })
      expect(results).to include({ stage: 'B', value: 200 })
      expect(results).to include({ stage: 'C', value: 300 })
    end
  end

  describe 'error handling' do
    it 'logs error when target stage does not exist' do
      klass = Class.new do
        include Minigun::DSL

        pipeline do
          producer :gen do
            emit(1)
          end

          stage :router do |item|
            emit_to_stage(:nonexistent_stage, item)
          end

          consumer :actual_stage do |item|
            # This should not be reached
          end
        end
      end

      pipeline = klass.new

      # Should log error but not crash
      expect { pipeline.run }.not_to raise_error
    end

    it 'continues processing after routing to invalid stage' do
      results = []

      klass = Class.new do
        include Minigun::DSL

        define_method(:initialize) do
          @results = results
        end

        pipeline do
          producer :gen do
            emit(1)
            emit(2)
          end

          stage :router do |item|
            if item == 1
              emit_to_stage(:nonexistent, item)
            else
              emit_to_stage(:valid, item)
            end
          end

          consumer :valid do |item|
            @results << item
          end
        end
      end

      pipeline = klass.new
      pipeline.run

      # Should process the valid item despite invalid routing
      expect(results).to eq([2])
    end
  end

  describe 'execution context integration' do
    it 'works with threaded consumers' do
      results = []
      mutex = Mutex.new

      klass = Class.new do
        include Minigun::DSL

        define_method(:initialize) do
          @results = results
          @mutex = mutex
        end

        pipeline do
          producer :gen do
            5.times { |i| emit(i) }
          end

          stage :router do |item|
            if item.even?
              emit_to_stage(:even_processor, item)
            else
              emit_to_stage(:odd_processor, item)
            end
          end

          threads(2) do
            consumer :even_processor do |item|
              sleep 0.01
              @mutex.synchronize { @results << { type: :even, value: item } }
            end

            consumer :odd_processor do |item|
              sleep 0.01
              @mutex.synchronize { @results << { type: :odd, value: item } }
            end
          end
        end
      end

      pipeline = klass.new
      pipeline.run

      expect(results.size).to eq(5)
      expect(results.select { |r| r[:type] == :even }.size).to eq(3)  # 0, 2, 4
      expect(results.select { |r| r[:type] == :odd }.size).to eq(2)   # 1, 3
    end

    it 'works across different execution contexts' do
      results = []
      mutex = Mutex.new

      klass = Class.new do
        include Minigun::DSL

        define_method(:initialize) do
          @results = results
          @mutex = mutex
        end

        pipeline do
          producer :gen do
            emit({ type: 'light', value: 1 })
            emit({ type: 'heavy', value: 2 })
          end

          stage :router do |item|
            case item[:type]
            when 'light'
              emit_to_stage(:light_processor, item)
            when 'heavy'
              emit_to_stage(:heavy_processor, item)
            end
          end

          # Light processor in thread pool
          threads(2) do
            consumer :light_processor do |item|
              @mutex.synchronize { @results << { type: :thread, value: item[:value] } }
            end
          end

          # Heavy processor in thread pool (not fork - simpler for this test)
          threads(1) do
            consumer :heavy_processor do |item|
              @mutex.synchronize { @results << { type: :thread_heavy, value: item[:value] } }
            end
          end
        end
      end

      pipeline = klass.new
      pipeline.run

      expect(results.size).to eq(2)
      expect(results.map { |r| r[:value] }.sort).to eq([1, 2])
    end

    it 'works across different execution contexts with forked processes' do
      results = []
      temp_file = Tempfile.new(['minigun_emit_to_stage_fork', '.json'])
      temp_file.close

      klass = Class.new do
        include Minigun::DSL

        define_method(:initialize) do |temp_file_path|
          @results = results
          @temp_file_path = temp_file_path
        end

        pipeline do
          producer :gen do
            emit({ type: 'light', value: 1 })
            emit({ type: 'heavy', value: 2 })
          end

          stage :router do |item|
            case item[:type]
            when 'light'
              emit_to_stage(:light_processor, item)
            when 'heavy'
              emit_to_stage(:heavy_processor, item)
            end
          end

          # Light processor in thread pool
          threads(2) do
            consumer :light_processor do |item|
              @results << { type: :thread, value: item[:value] }
            end
          end

          # Heavy processor in forked processes (requires tempfile IPC)
          # Note: process_per_batch receives an array of items, not individual items
          process_per_batch(max: 1) do
            consumer :heavy_processor do |items|
              # Write to temp file (fork-safe)
              File.open(@temp_file_path, 'a') do |f|
                f.flock(File::LOCK_EX)
                # Handle both single items and arrays
                items_array = items.is_a?(Array) ? items : [items]
                items_array.each do |item|
                  f.puts({ type: :process, value: item[:value] }.to_json)
                end
                f.flock(File::LOCK_UN)
              end
            end
          end
          
          after_run do
            # Read fork results from temp file
            if File.exist?(@temp_file_path)
              fork_results = File.readlines(@temp_file_path).map { |line| JSON.parse(line.strip, symbolize_names: true) }
              @results.concat(fork_results)
            end
          end
        end
      end

      begin
        pipeline = klass.new(temp_file.path)
        pipeline.run

        expect(results.size).to eq(2)
        expect(results.map { |r| r[:value] }.sort).to eq([1, 2])
        expect(results.map { |r| r[:type] }.sort).to eq([:process, :thread])
      ensure
        File.unlink(temp_file.path) if temp_file && File.exist?(temp_file.path)
      end
    end
  end

  describe 'complex routing patterns' do
    it 'supports conditional routing logic' do
      results = []

      klass = Class.new do
        include Minigun::DSL

        define_method(:initialize) do
          @results = results
        end

        pipeline do
          producer :gen do
            emit({ priority: 'high', data: 'urgent' })
            emit({ priority: 'low', data: 'delayed' })
            emit({ priority: 'medium', data: 'normal' })
          end

          stage :priority_router do |item|
            target = case item[:priority]
                     when 'high'
                       :high_priority_handler
                     when 'medium'
                       :medium_priority_handler
                     when 'low'
                       :low_priority_handler
                     else
                       :default_handler
                     end

            emit_to_stage(target, item)
          end

          consumer :high_priority_handler do |item|
            @results << { priority: :high, data: item[:data] }
          end

          consumer :medium_priority_handler do |item|
            @results << { priority: :medium, data: item[:data] }
          end

          consumer :low_priority_handler do |item|
            @results << { priority: :low, data: item[:data] }
          end

          consumer :default_handler do |item|
            @results << { priority: :default, data: item[:data] }
          end
        end
      end

      pipeline = klass.new
      pipeline.run

      expect(results.size).to eq(3)
      expect(results).to include({ priority: :high, data: 'urgent' })
      expect(results).to include({ priority: :medium, data: 'normal' })
      expect(results).to include({ priority: :low, data: 'delayed' })
    end

    it 'supports load balancing pattern' do
      results = []
      mutex = Mutex.new

      klass = Class.new do
        include Minigun::DSL

        define_method(:initialize) do
          @results = results
          @mutex = mutex
          @counter = 0
        end

        pipeline do
          producer :gen do
            10.times { |i| emit(i) }
          end

          stage :load_balancer do |item|
            # Round-robin across 3 workers
            worker = @counter % 3
            @counter += 1
            emit_to_stage(:"worker_#{worker}", item)
          end

          consumer :worker_0 do |item|
            @mutex.synchronize { @results << { worker: 0, item: item } }
          end

          consumer :worker_1 do |item|
            @mutex.synchronize { @results << { worker: 1, item: item } }
          end

          consumer :worker_2 do |item|
            @mutex.synchronize { @results << { worker: 2, item: item } }
          end
        end
      end

      pipeline = klass.new
      pipeline.run

      expect(results.size).to eq(10)

      # Check distribution
      worker_0_count = results.select { |r| r[:worker] == 0 }.size
      worker_1_count = results.select { |r| r[:worker] == 1 }.size
      worker_2_count = results.select { |r| r[:worker] == 2 }.size

      # Round robin should distribute relatively evenly (3-4 items per worker)
      expect(worker_0_count).to be_between(3, 4)
      expect(worker_1_count).to be_between(3, 4)
      expect(worker_2_count).to be_between(3, 4)
    end

    it 'supports multi-level routing' do
      results = []

      klass = Class.new do
        include Minigun::DSL

        define_method(:initialize) do
          @results = results
        end

        pipeline do
          producer :gen do
            emit({ category: 'email', type: 'transactional', id: 1 })
            emit({ category: 'email', type: 'marketing', id: 2 })
            emit({ category: 'sms', type: 'transactional', id: 3 })
          end

          stage :category_router do |item|
            if item[:category] == 'email'
              emit_to_stage(:email_type_router, item)
            else
              emit_to_stage(:sms_handler, item)
            end
          end

          stage :email_type_router do |item|
            if item[:type] == 'transactional'
              emit_to_stage(:email_transactional, item)
            else
              emit_to_stage(:email_marketing, item)
            end
          end

          consumer :email_transactional do |item|
            @results << { handler: :email_transactional, id: item[:id] }
          end

          consumer :email_marketing do |item|
            @results << { handler: :email_marketing, id: item[:id] }
          end

          consumer :sms_handler do |item|
            @results << { handler: :sms, id: item[:id] }
          end
        end
      end

      pipeline = klass.new
      pipeline.run

      expect(results.size).to eq(3)
      expect(results).to include({ handler: :email_transactional, id: 1 })
      expect(results).to include({ handler: :email_marketing, id: 2 })
      expect(results).to include({ handler: :sms, id: 3 })
    end
  end

  describe 'batching with emit_to_stage' do
    it 'supports custom batching with dynamic routing' do
      results = []

      klass = Class.new do
        include Minigun::DSL

        define_method(:initialize) do
          @results = results
        end

        pipeline do
          producer :gen do
            emit({ type: 'A', value: 1 })
            emit({ type: 'B', value: 2 })
            emit({ type: 'A', value: 3 })
            emit({ type: 'B', value: 4 })
            emit({ type: 'A', value: 5 })
          end

          stage :type_batcher do |item|
            @batches ||= Hash.new { |h, k| h[k] = [] }
            @batches[item[:type]] << item

            # Emit batch when size reaches 2
            if @batches[item[:type]].size >= 2
              batch = @batches[item[:type]].dup
              @batches[item[:type]].clear
              emit_to_stage(:"#{item[:type]}_handler", batch)
            end
          end

          consumer :A_handler do |batch|
            @results << { type: 'A', batch_size: batch.size, values: batch.map { |i| i[:value] } }
          end

          consumer :B_handler do |batch|
            @results << { type: 'B', batch_size: batch.size, values: batch.map { |i| i[:value] } }
          end
        end
      end

      pipeline = klass.new
      pipeline.run

      # Should have 1 batch of type A (values 1, 3) and 1 batch of type B (values 2, 4)
      # Value 5 (type A) remains unbatched
      expect(results.size).to eq(2)

      type_a_batch = results.find { |r| r[:type] == 'A' }
      type_b_batch = results.find { |r| r[:type] == 'B' }

      expect(type_a_batch[:batch_size]).to eq(2)
      expect(type_a_batch[:values]).to eq([1, 3])

      expect(type_b_batch[:batch_size]).to eq(2)
      expect(type_b_batch[:values]).to eq([2, 4])
    end
  end

  describe 'AtomicStage#execute_with_emit' do
    it 'returns plain items when only emit is used' do
      stage = Minigun::AtomicStage.new(
        name: :test,
        block: proc { |item| emit(item * 2) }
      )

      context = Object.new
      results = stage.execute_with_emit(context, 5)

      expect(results).to eq([10])
    end

    it 'returns hash with target when emit_to_stage is used' do
      stage = Minigun::AtomicStage.new(
        name: :test,
        block: proc { |item| emit_to_stage(:target, item * 2) }
      )

      context = Object.new
      results = stage.execute_with_emit(context, 5)

      expect(results.size).to eq(1)
      expect(results.first).to eq({ item: 10, target: :target })
    end

    it 'returns array with both plain items and targeted items' do
      stage = Minigun::AtomicStage.new(
        name: :test,
        block: proc do |item|
          emit(item * 2)
          emit_to_stage(:specific, item * 3)
          emit(item * 4)
        end
      )

      context = Object.new
      results = stage.execute_with_emit(context, 5)

      expect(results.size).to eq(3)
      # All items in emissions array, mixed types
      expect(results[0]).to eq(10)  # Plain item from emit
      expect(results[1]).to eq({ item: 15, target: :specific })  # Targeted item
      expect(results[2]).to eq(20)  # Plain item from emit
    end
  end
end

