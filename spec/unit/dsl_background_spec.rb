# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Minigun::DSL, 'Background Execution' do
  # Quick task that completes fast
  let(:task_class) do
    Class.new do
      include Minigun::DSL

      attr_reader :items_processed

      def initialize
        @items_processed = []
      end

      pipeline do
        producer :generate do |output|
          5.times { |i| output << i }
        end

        consumer :process do |item, _output|
          @items_processed << item
        end
      end
    end
  end

  # Long-running task for testing running? and stop
  let(:infinite_task_class) do
    Class.new do
      include Minigun::DSL

      attr_reader :items_processed

      def initialize
        @items_processed = []
      end

      pipeline do
        producer :generate do |output|
          counter = 0
          loop do
            output << counter
            counter += 1
            sleep 0.1 # Slow enough to test
          end
        end

        consumer :process do |item, _output|
          @items_processed << item
          sleep 0.05
        end
      end
    end
  end

  describe '#run with background: true' do
    it 'runs task in background thread' do
      task = infinite_task_class.new
      result = task.run(background: true)

      sleep 0.2 # Give it time to start

      expect(result).to eq(task)
      expect(task.running?).to be true

      # Stop it
      task.stop

      expect(task.running?).to be false
    end

    it 'returns immediately' do
      task = infinite_task_class.new

      start_time = Time.now
      task.run(background: true)
      elapsed = Time.now - start_time

      # Should return almost immediately (< 0.3s including sleep)
      expect(elapsed).to be < 0.3

      sleep 0.1  # Give it time to actually start

      expect(task.running?).to be true

      task.stop
    end

    it 'completes short tasks' do
      task = task_class.new
      task.run(background: true)

      task.wait

      expect(task.running?).to be false
      expect(task.items_processed.size).to eq(5)
    end
  end

  describe '#perform with background: true' do
    it 'runs pipeline in background' do
      task = infinite_task_class.new
      task.perform(background: true)

      sleep 0.2  # Give it time to start

      expect(task.running?).to be true

      task.stop
    end
  end

  describe '#running?' do
    it 'returns false when not running' do
      task = task_class.new
      expect(task.running?).to be false
    end

    it 'returns true when running in background' do
      task = infinite_task_class.new
      task.run(background: true)

      sleep 0.2  # Give it time to start

      expect(task.running?).to be true
      task.stop
    end

    it 'returns false after task completes' do
      task = task_class.new
      task.run(background: true)
      task.wait
      expect(task.running?).to be false
    end
  end

  describe '#stop' do
    it 'stops background execution' do
      task = infinite_task_class.new
      task.run(background: true)

      sleep 0.2  # Give it time to start

      expect(task.running?).to be true

      task.stop

      expect(task.running?).to be false
    end

    it 'handles being called when not running' do
      task = task_class.new
      expect { task.stop }.not_to raise_error
    end
  end

  describe '#wait' do
    it 'waits for background task to complete' do
      task = task_class.new
      task.run(background: true)

      task.wait

      expect(task.running?).to be false
      expect(task.items_processed.size).to eq(5)
    end

    it 'handles being called when not running' do
      task = task_class.new
      expect { task.wait }.not_to raise_error
    end
  end

  describe '#hud' do
    it 'raises error if task not initialized' do
      task = task_class.new

      expect { task.hud }.to raise_error(/not initialized/)
    end

    it 'raises error if pipeline stats not initialized' do
      task = task_class.new
      # Initialize pipeline but don't run it
      task.send(:_evaluate_pipeline_blocks!)

      expect { task.hud }.to raise_error(/stats not initialized/)
    end

    it 'loads HUD module and launches it' do
      # Pre-load HUD module for mocking
      require 'minigun/hud'

      task = infinite_task_class.new
      task.run(background: true)

      sleep 0.2 # Give it time to start

      # Mock the HUD launch to prevent actual UI from opening
      expect(Minigun::HUD).to receive(:launch)

      expect { task.hud }.not_to raise_error

      task.stop
    end
  end

  describe 'error handling' do
    let(:error_task_class) do
      Class.new do
        include Minigun::DSL

        pipeline do
          producer :generate do |output|
            output << 1
            raise 'Test error'
          end

          consumer :process do |_item, _output|
            # Won't be reached
          end
        end
      end
    end

    it 'captures errors in background thread' do
      task = error_task_class.new

      # Suppress error output during test
      allow($stderr).to receive(:write)

      task.run(background: true)

      # Wait a bit for error to occur
      sleep 0.5

      # Thread should have died due to error
      expect(task.running?).to be false
    end
  end
end
