# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Functional DSL' do
  before do
    allow(Minigun.logger).to receive(:info)
    allow(Minigun.logger).to receive(:debug)
  end

  describe 'Minigun.task' do
    it 'creates a task with a name' do
      task = Minigun.task('my_task') do
        producer :source do |output|
          output << 1
        end
      end

      expect(task.instance_variable_get(:@task_name)).to eq('my_task')
    end

    it 'creates a task without a name' do
      task = Minigun.task do
        producer :source do |output|
          output << 1
        end
      end

      expect(task.instance_variable_get(:@task_name)).to be_nil
    end

    it 'returns an object that responds to run' do
      task = Minigun.task('test') do
        producer :source do |output|
          output << 1
        end
        consumer :sink do |_item|
          # no-op
        end
      end

      expect(task).to respond_to(:run)
    end

    it 'returns an object that responds to start' do
      task = Minigun.task('test') do
        producer :source do |output|
          output << 1
        end
        consumer :sink do |_item|
          # no-op
        end
      end

      expect(task).to respond_to(:start)
    end

    it 'executes the pipeline when run is called' do
      results = []
      mutex = Mutex.new

      task = Minigun.task('test') do
        producer :source do |output|
          3.times { |i| output << i }
        end

        consumer :sink do |item|
          mutex.synchronize { results << item }
        end
      end

      task.run
      expect(results.sort).to eq([0, 1, 2])
    end

    it 'can access instance variables defined in the block' do
      task = Minigun.task('test') do
        @results = []
        @mutex = Mutex.new

        producer :source do |output|
          3.times { |i| output << i }
        end

        consumer :sink do |item|
          @mutex.synchronize { @results << item }
        end
      end

      task.run
      expect(task.instance_variable_get(:@results).sort).to eq([0, 1, 2])
    end
  end

  describe 'task.start' do
    it 'runs the task in background' do
      results = []
      mutex = Mutex.new

      task = Minigun.task('background_test') do
        producer :source do |output|
          3.times { |i| output << i }
        end

        consumer :sink do |item|
          mutex.synchronize { results << item }
        end
      end

      # Capture stdout to suppress background messages
      original_stdout = $stdout
      $stdout = StringIO.new

      begin
        task.start
        expect(task.running?).to be(true).or be(false) # May have finished quickly
        task.wait
      ensure
        $stdout = original_stdout
      end

      expect(results.sort).to eq([0, 1, 2])
    end
  end

  describe 'produce alias' do
    it 'works as an alias for producer' do
      results = []
      mutex = Mutex.new

      task = Minigun.task('produce_test') do
        produce :source do |output|
          3.times { |i| output << i }
        end

        consumer :sink do |item|
          mutex.synchronize { results << item }
        end
      end

      task.run
      expect(results.sort).to eq([0, 1, 2])
    end
  end

  describe 'consume alias' do
    it 'works as an alias for consumer' do
      results = []
      mutex = Mutex.new

      task = Minigun.task('consume_test') do
        producer :source do |output|
          3.times { |i| output << i }
        end

        consume :sink do |item|
          mutex.synchronize { results << item }
        end
      end

      task.run
      expect(results.sort).to eq([0, 1, 2])
    end
  end

  describe 'in_threads' do
    it 'executes stages in thread pool' do
      results = []
      mutex = Mutex.new
      thread_ids = []

      task = Minigun.task('threads_test') do
        producer :source do |output|
          10.times { |i| output << i }
        end

        in_threads(3) do
          consumer :sink do |item|
            mutex.synchronize do
              results << item
              thread_ids << Thread.current.object_id
            end
          end
        end
      end

      task.run
      expect(results.sort).to eq((0..9).to_a)
      # Should have used multiple threads (though not guaranteed all 3)
      expect(thread_ids.uniq.size).to be >= 1
    end

    it 'respects pool size limit' do
      concurrent_count = Concurrent::AtomicFixnum.new(0)
      max_concurrent = Concurrent::AtomicFixnum.new(0)

      task = Minigun.task('pool_limit_test') do
        producer :source do |output|
          20.times { |i| output << i }
        end

        in_threads(2) do
          consumer :sink do |_item|
            current = concurrent_count.increment
            max_concurrent.update { |v| [v, current].max }
            sleep 0.01
            concurrent_count.decrement
          end
        end
      end

      task.run
      expect(max_concurrent.value).to be <= 2
    end
  end

  describe 'in_cow_forks', if: Minigun.fork? do
    it 'executes stages in forked processes' do
      task = Minigun.task('cow_forks_test') do
        producer :source do |output|
          3.times { |i| output << i }
        end

        in_cow_forks(2) do
          consumer :sink do |item|
            # Just verify it runs without error
            item * 2
          end
        end
      end

      # Should complete without error
      expect { task.run }.not_to raise_error
    end
  end

  describe 'in_ipc_forks', if: Minigun.fork? do
    it 'executes stages in IPC forked processes' do
      task = Minigun.task('ipc_forks_test') do
        producer :source do |output|
          3.times { |i| output << i }
        end

        in_ipc_forks(2) do
          consumer :sink do |item|
            # Just verify it runs without error
            item * 2
          end
        end
      end

      # Should complete without error
      expect { task.run }.not_to raise_error
    end
  end

  describe 'debatch' do
    it 'unpacks arrays into individual items' do
      results = []
      mutex = Mutex.new

      task = Minigun.task('debatch_test') do
        producer :source do |output|
          output << [1, 2, 3]
          output << [4, 5, 6]
          output << [7, 8, 9]
        end

        debatch

        consumer :sink do |item|
          mutex.synchronize { results << item }
        end
      end

      task.run
      expect(results.sort).to eq((1..9).to_a)
    end

    it 'passes through non-array items unchanged' do
      results = []
      mutex = Mutex.new

      task = Minigun.task('debatch_passthrough_test') do
        producer :source do |output|
          output << 'single_item'
          output << [1, 2]
        end

        debatch

        consumer :sink do |item|
          mutex.synchronize { results << item }
        end
      end

      task.run
      expect(results).to contain_exactly('single_item', 1, 2)
    end

    it 'handles empty arrays' do
      results = []
      mutex = Mutex.new

      task = Minigun.task('debatch_empty_test') do
        producer :source do |output|
          output << []
          output << [1]
        end

        debatch

        consumer :sink do |item|
          mutex.synchronize { results << item }
        end
      end

      task.run
      expect(results).to eq([1])
    end

    it 'accepts optional name parameter' do
      task = Minigun.task('debatch_named_test') do
        producer :source do |output|
          output << [1, 2]
        end

        debatch :my_debatcher

        consumer :sink do |_item|
          # no-op
        end
      end

      task.run
      stage = task._minigun_task.root_pipeline.find_stage(:my_debatcher)
      expect(stage).not_to be_nil
      expect(stage.name).to eq(:my_debatcher)
    end

    it 'works with execution contexts' do
      results = []
      mutex = Mutex.new

      task = Minigun.task('debatch_threaded_test') do
        producer :source do |output|
          output << [1, 2, 3]
          output << [4, 5, 6]
        end

        in_threads(2) do
          debatch

          consumer :sink do |item|
            mutex.synchronize { results << item }
          end
        end
      end

      task.run
      expect(results.sort).to eq((1..6).to_a)
    end
  end

  describe 'rebatch' do
    it 're-batches incoming batches into smaller size' do
      results = []
      mutex = Mutex.new

      task = Minigun.task('rebatch_downsize_test') do
        producer :source do |output|
          # Send 3 batches of 100 items each
          3.times do |batch_num|
            batch = (1..100).map { |i| (batch_num * 100) + i }
            output << batch
          end
        end

        rebatch(20)

        consumer :sink do |batch|
          mutex.synchronize { results << batch.size }
        end
      end

      task.run

      # 300 items rebatched into groups of 20 = 15 batches
      expect(results.size).to eq(15)
      expect(results).to all(eq(20))
    end

    it 're-batches incoming batches into larger size' do
      results = []
      mutex = Mutex.new

      task = Minigun.task('rebatch_upsize_test') do
        producer :source do |output|
          # Send 15 batches of 20 items each (300 total)
          15.times do |batch_num|
            batch = (1..20).map { |i| (batch_num * 20) + i }
            output << batch
          end
        end

        rebatch(100)

        consumer :sink do |batch|
          mutex.synchronize { results << batch.size }
        end
      end

      task.run

      # 300 items rebatched into groups of 100 = 3 batches
      expect(results.size).to eq(3)
      expect(results).to all(eq(100))
    end

    it 'handles remainder batches' do
      results = []
      mutex = Mutex.new

      task = Minigun.task('rebatch_remainder_test') do
        producer :source do |output|
          # Send 2 batches of 50 items each (100 total)
          2.times do |batch_num|
            batch = (1..50).map { |i| (batch_num * 50) + i }
            output << batch
          end
        end

        rebatch(30)

        consumer :sink do |batch|
          mutex.synchronize { results << batch.size }
        end
      end

      task.run

      # 100 items rebatched into groups of 30 = 3 batches of 30 + 1 of 10
      expect(results.size).to eq(4)
      expect(results[0..2]).to all(eq(30))
      expect(results[3]).to eq(10)
    end

    it 'handles single items (non-batch input)' do
      results = []
      mutex = Mutex.new

      task = Minigun.task('rebatch_single_items_test') do
        producer :source do |output|
          10.times { |i| output << i }
        end

        rebatch(3)

        consumer :sink do |batch|
          mutex.synchronize { results << batch }
        end
      end

      task.run

      # 10 single items rebatched into groups of 3
      expect(results.size).to eq(4)
      expect(results[0]).to eq([0, 1, 2])
      expect(results[1]).to eq([3, 4, 5])
      expect(results[2]).to eq([6, 7, 8])
      expect(results[3]).to eq([9])
    end

    it 'accepts optional name parameter' do
      task = Minigun.task('rebatch_named_test') do
        producer :source do |output|
          output << [1, 2, 3]
        end

        rebatch(2, :my_batcher)

        consumer :sink do |_batch|
          # no-op
        end
      end

      task.run
      stage = task._minigun_task.root_pipeline.find_stage(:my_batcher)
      expect(stage).not_to be_nil
      expect(stage.name).to eq(:my_batcher)
    end

    it 'works with debatch for resizing batches' do
      results = []
      mutex = Mutex.new

      task = Minigun.task('debatch_rebatch_test') do
        producer :source do |output|
          # Send batches of 5
          output << [1, 2, 3, 4, 5]
          output << [6, 7, 8, 9, 10]
        end

        debatch
        rebatch(3)

        consumer :sink do |batch|
          mutex.synchronize { results << batch }
        end
      end

      task.run

      # 10 items rebatched into groups of 3
      expect(results.flatten.sort).to eq((1..10).to_a)
      expect(results.map(&:size)).to eq([3, 3, 3, 1])
    end
  end

  describe 'combined functionality' do
    it 'supports the newsletter sender pattern' do
      sent_to = []
      mutex = Mutex.new

      # Simulated user batches
      user_batches = [
        (1..5).map { |i| { id: i, email: "user#{i}@example.com" } },
        (6..10).map { |i| { id: i, email: "user#{i}@example.com" } }
      ]

      task = Minigun.task('newsletter_sender') do
        produce :batches do |output|
          user_batches.each { |batch| output << batch }
        end

        debatch

        in_threads(3) do
          consume :send_email do |user|
            mutex.synchronize { sent_to << user[:id] }
          end
        end
      end

      task.run
      expect(sent_to.sort).to eq((1..10).to_a)
    end

    it 'supports nested execution contexts' do
      results = []
      mutex = Mutex.new

      task = Minigun.task('nested_contexts') do
        produce :source do |output|
          [[1, 2], [3, 4], [5, 6]].each { |batch| output << batch }
        end

        in_threads(2) do
          debatch

          in_threads(2) do
            consume :sink do |item|
              mutex.synchronize { results << (item * 10) }
            end
          end
        end
      end

      task.run
      expect(results.sort).to eq([10, 20, 30, 40, 50, 60])
    end
  end
end
