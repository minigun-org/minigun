# frozen_string_literal: true

require 'spec_helper'
require 'tempfile'
require 'json'

RSpec.describe 'output.to(:stage) routing' do
  describe 'basic functionality' do
    it 'routes items to explicitly named stage' do
      results = []

      klass = Class.new do
        include Minigun::DSL

        define_method(:initialize) do
          @results = results
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

      expect(results.size).to eq(3)
      expect(results.select { |r| r[:stage] == :fast }.size).to eq(2)
      expect(results.select { |r| r[:stage] == :slow }.size).to eq(1)
      expect(results.map { |r| r[:id] }.sort).to eq([1, 2, 3])
    end

    it 'allows mixing default routing and explicit routing in same stage' do
      results = []

      klass = Class.new do
        include Minigun::DSL

        define_method(:initialize) do
          @results = results
        end

        pipeline do
          producer :gen do |output|
            output << 1
            output << 2
          end

          processor :router do |item, output|
            if item == 1
              output << item * 10  # Regular output - goes to next stage via DAG
            else
              output.to(:special) << item * 100  # Targeted output
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

    it 'can route to multiple stages in single stage block' do
      results = []

      klass = Class.new do
        include Minigun::DSL

        define_method(:initialize) do
          @results = results
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

      expect(results.size).to eq(3)
      expect(results).to include({ stage: 'A', value: 100 })
      expect(results).to include({ stage: 'B', value: 200 })
      expect(results).to include({ stage: 'C', value: 300 })
    end
  end

  describe 'error handling' do
    it 'logs warning when target stage does not exist' do
      klass = Class.new do
        include Minigun::DSL

        pipeline do
          producer :gen do |output|
            output << 1
          end

          processor :router do |item, output|
            output.to(:nonexistent_stage) << item
          end

          consumer :actual_stage do |item|
            # This should not be reached
          end
        end
      end

      pipeline = klass.new

      # Should log warning but not crash
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
          producer :gen do |output|
            output << 1
            output << 2
          end

          processor :router do |item, output|
            if item == 1
              output.to(:nonexistent) << item
            else
              output.to(:valid) << item
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
          producer :gen do |output|
            5.times { |i| output << i }
          end

          processor :router do |item, output|
            if item.even?
              output.to(:even_processor) << item
            else
              output.to(:odd_processor) << item
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
          producer :gen do |output|
            output << { type: 'light', value: 1 }
            output << { type: 'heavy', value: 2 }
          end

          processor :router do |item, output|
            case item[:type]
            when 'light'
              output.to(:light_processor) << item
            when 'heavy'
              output.to(:heavy_processor) << item
            end
          end

          # Light processor in thread pool
          threads(2) do
            consumer :light_processor do |item|
              @mutex.synchronize { @results << { type: :thread, value: item[:value] } }
            end
          end

          # Heavy processor in thread pool
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

    it 'works with inline and threaded contexts mixed' do
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

    it 'works across different execution contexts with forked processes' do
      results = []
      temp_file = Tempfile.new(['minigun_output_to_stage_fork', '.json'])
      temp_file.close

      klass = Class.new do
        include Minigun::DSL

        define_method(:initialize) do |temp_file_path|
          @results = results
          @temp_file_path = temp_file_path
          @fork_results_read = false
        end

        pipeline do
          producer :gen do |output|
            output << { type: 'light', value: 1 }
            output << { type: 'heavy', value: 2 }
          end

          processor :router do |item, output|
            case item[:type]
            when 'light'
              output.to(:light_processor) << item
            when 'heavy'
              output.to(:heavy_processor) << item
            end
          end

          # Light processor in thread pool
          threads(2) do
            consumer :light_processor do |item|
              @results << { 'type' => 'thread', 'value' => item[:value] }
            end
          end

          # Heavy processor in forked processes (requires tempfile IPC)
          process_per_batch(max: 1) do
            consumer :heavy_processor do |item|
              # Write to temp file (fork-safe)
              File.open(@temp_file_path, 'a') do |f|
                f.flock(File::LOCK_EX)
                f.puts({ 'type' => 'process', 'value' => item[:value] }.to_json)
                f.flock(File::LOCK_UN)
              end
            end
          end

          after_run do
            # Read fork results from temp file (only once!)
            unless @fork_results_read
              @fork_results_read = true
              if File.exist?(@temp_file_path)
                fork_results = File.readlines(@temp_file_path).map { |line| JSON.parse(line.strip) }
                @results.concat(fork_results)
              end
            end
          end
        end
      end

      begin
        pipeline = klass.new(temp_file.path)
        pipeline.run

        expect(results.size).to eq(2)
        expect(results.map { |r| r['value'] }.sort).to eq([1, 2])
        expect(results.map { |r| r['type'] }.sort).to eq(['process', 'thread'])
      ensure
        File.unlink(temp_file.path) if temp_file && File.exist?(temp_file.path)
      end
    end
  end

  describe 'complex routing patterns' do
    it 'supports conditional routing logic with multiple conditions' do
      results = []

      klass = Class.new do
        include Minigun::DSL

        define_method(:initialize) do
          @results = results
        end

        pipeline do
          producer :gen do |output|
            output << { priority: 'high', data: 'urgent' }
            output << { priority: 'low', data: 'delayed' }
            output << { priority: 'medium', data: 'normal' }
          end

          processor :priority_router do |item, output|
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

            output.to(target) << item
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

    it 'supports range-based conditional routing' do
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

    it 'supports load balancing pattern with round-robin' do
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
          producer :gen do |output|
            10.times { |i| output << i }
          end

          processor :load_balancer do |item, output|
            # Round-robin across 3 workers
            worker = @counter % 3
            @counter += 1
            output.to(:"worker_#{worker}") << item
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

    it 'supports multi-level routing (cascade)' do
      results = []

      klass = Class.new do
        include Minigun::DSL

        define_method(:initialize) do
          @results = results
        end

        pipeline do
          producer :gen do |output|
            output << { category: 'email', type: 'transactional', id: 1 }
            output << { category: 'email', type: 'marketing', id: 2 }
            output << { category: 'sms', type: 'transactional', id: 3 }
          end

          processor :category_router do |item, output|
            if item[:category] == 'email'
              output.to(:email_type_router) << item
            else
              output.to(:sms_handler) << item
            end
          end

          processor :email_type_router do |item, output|
            if item[:type] == 'transactional'
              output.to(:email_transactional) << item
            else
              output.to(:email_marketing) << item
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

    it 'supports multi-level routing with processor chain' do
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

  describe 'batching with dynamic routing' do
    it 'supports custom batching with type-based routing' do
      results = []

      klass = Class.new do
        include Minigun::DSL

        define_method(:initialize) do
          @results = results
        end

        pipeline do
          producer :gen do |output|
            output << { type: 'A', value: 1 }
            output << { type: 'B', value: 2 }
            output << { type: 'A', value: 3 }
            output << { type: 'B', value: 4 }
            output << { type: 'A', value: 5 }
          end

          processor :type_batcher do |item, output|
            @batches ||= Hash.new { |h, k| h[k] = [] }
            @batches[item[:type]] << item

            # Emit batch when size reaches 2
            if @batches[item[:type]].size >= 2
              batch = @batches[item[:type]].dup
              @batches[item[:type]].clear
              output.to(:"#{item[:type]}_handler") << batch
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

    it 'supports batching with message type routing' do
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

