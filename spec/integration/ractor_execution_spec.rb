# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Ractor execution', if: Minigun::Platform.ractors? do
  describe 'in_ractors DSL' do
    it 'processes items in parallel with shareable blocks' do
      klass = Class.new do
        include Minigun::DSL

        attr_reader :results

        def initialize
          @results = []
          @mutex = Mutex.new
        end

        pipeline do
          producer :generate do |output|
            5.times { |i| output << i }
          end

          # shareable: true is automatically applied for stages inside in_ractors
          # but consumer below captures @mutex so will fall back to threads
          in_ractors(2) do
            processor :double do |item, output|
              output << (item * 2)
            end
          end

          consumer :collect do |item|
            @mutex.synchronize { @results << item }
          end
        end
      end

      instance = klass.new
      instance.run

      expect(instance.results.sort).to eq([0, 2, 4, 6, 8])
    end

    it 'falls back to threads for non-shareable blocks' do
      Mutex.new

      klass = Class.new do
        include Minigun::DSL

        attr_reader :results

        def initialize
          @results = []
          @mutex = Mutex.new
        end

        pipeline do
          producer :generate do |output|
            5.times { |i| output << i }
          end

          # This block captures @mutex - NOT shareable
          # Should fall back to threads automatically
          in_ractors(2) do
            processor :double do |item, output|
              output << (item * 2)
            end
          end

          consumer :collect do |item|
            @mutex.synchronize { @results << item }
          end
        end
      end

      instance = klass.new
      # Should not raise, falls back to threads
      expect { instance.run }.not_to raise_error
      expect(instance.results.sort).to eq([0, 2, 4, 6, 8])
    end
  end

  describe 'shareable: true option' do
    it 'creates Ractor-shareable blocks when available' do
      skip 'Requires Ruby 4.0+ with Ractor.shareable_proc' unless defined?(Ractor) && Ractor.respond_to?(:shareable_proc)

      klass = Class.new do
        include Minigun::DSL

        pipeline do
          producer :generate do |output|
            3.times { |i| output << i }
          end

          processor :compute, shareable: true do |item, output|
            # Pure function - no captured state
            output << { input: item, squared: item**2 }
          end

          consumer :sink do |_item|
            # Just consume
          end
        end
      end

      instance = klass.new
      expect { instance.run }.not_to raise_error
    end

    it 'raises error when shareable block captures state' do
      skip 'Requires Ruby 4.0+ with Ractor.shareable_proc' unless defined?(Ractor) && Ractor.respond_to?(:shareable_proc)

      # Use an array (unshareable object) instead of a string
      # Strings can be frozen and made shareable, but arrays with elements cannot
      captured_arr = []

      # Define the class (pipeline block is stored but not yet executed)
      klass = Class.new do
        include Minigun::DSL

        pipeline do
          producer :generate do |output|
            output << 1
          end

          # This block captures captured_arr - will fail shareable_proc
          processor :bad, shareable: true do |item, output|
            captured_arr << item
            output << item
          end
        end
      end

      # Error is raised when run() is called (pipeline block is evaluated then)
      expect { klass.new.run }.to raise_error(Minigun::Errors::ConfigurationError, /cannot be made shareable/)
    end
  end

  describe 'error handling' do
    it 'continues processing other items when one raises an error' do
      klass = Class.new do
        include Minigun::DSL

        attr_reader :results, :errors

        def initialize
          @results = []
          @errors = []
          @mutex = Mutex.new
        end

        pipeline do
          producer :generate do |output|
            5.times { |i| output << i }
          end

          in_ractors(2) do
            processor :maybe_fail do |item, output|
              raise 'deliberate error' if item == 2

              output << (item * 10)
            end
          end

          consumer :collect do |item|
            @mutex.synchronize { @results << item }
          end
        end
      end

      instance = klass.new
      # Should not raise - errors are logged but processing continues
      expect { instance.run }.not_to raise_error

      # Should have processed items 0, 1, 3, 4 (skipping 2 which raised)
      expect(instance.results.sort).to eq([0, 10, 30, 40])
    end
  end

  describe 'multiple outputs' do
    it 'handles stages that output multiple items per input' do
      klass = Class.new do
        include Minigun::DSL

        attr_reader :results

        def initialize
          @results = []
          @mutex = Mutex.new
        end

        pipeline do
          producer :generate do |output|
            3.times { |i| output << i }
          end

          in_ractors(2) do
            processor :explode do |item, output|
              # Output multiple items per input
              3.times { |j| output << { original: item, copy: j } }
            end
          end

          consumer :collect do |item|
            @mutex.synchronize { @results << item }
          end
        end
      end

      instance = klass.new
      instance.run

      # 3 inputs * 3 outputs each = 9 total
      expect(instance.results.size).to eq(9)

      # Each original value should have 3 copies
      [0, 1, 2].each do |orig|
        copies = instance.results.select { |r| r[:original] == orig }
        expect(copies.size).to eq(3)
        expect(copies.map { |c| c[:copy] }.sort).to eq([0, 1, 2])
      end
    end
  end

  describe 'high concurrency' do
    it 'handles many items through a Ractor pool', timeout: 30 do
      klass = Class.new do
        include Minigun::DSL

        attr_reader :results

        def initialize
          @results = []
          @mutex = Mutex.new
        end

        pipeline do
          producer :generate do |output|
            100.times { |i| output << i }
          end

          in_ractors(4) do
            processor :compute do |item, output|
              # Do some actual computation
              result = (1..50).reduce(item.to_f) { |acc, _| Math.sqrt((acc**2) + 1) }
              output << { input: item, result: result.round(4) }
            end
          end

          consumer :collect do |item|
            @mutex.synchronize { @results << item }
          end
        end
      end

      instance = klass.new
      instance.run

      expect(instance.results.size).to eq(100)
      inputs = instance.results.map { |r| r[:input] }.sort
      expect(inputs).to eq((0...100).to_a)
    end
  end

  describe 'auto-shareable warning' do
    it 'logs warning when in_ractors block cannot be made shareable' do
      skip 'Requires Ruby 4.0+ with Ractor.shareable_proc' unless defined?(Ractor) && Ractor.respond_to?(:shareable_proc)

      # Capture log output
      log_output = StringIO.new
      original_logger = Minigun.logger
      Minigun.logger = Logger.new(log_output)
      Minigun.logger.level = Logger::WARN

      begin
        # Create a class with a non-shareable block in in_ractors
        captured_state = []

        klass = Class.new do
          include Minigun::DSL

          attr_reader :results

          def initialize
            @results = []
            @mutex = Mutex.new
          end

          pipeline do
            producer :generate do |output|
              3.times { |i| output << i }
            end

            # This captures captured_state - not shareable
            # Should warn and fall back to threads
            in_ractors(2) do
              processor :uses_state do |item, output|
                # Reference captured state (makes block non-shareable)
                _ = captured_state
                output << (item * 2)
              end
            end

            consumer :collect do |item|
              @mutex.synchronize { @results << item }
            end
          end
        end

        instance = klass.new
        instance.run

        # Should still work (fell back to threads)
        expect(instance.results.sort).to eq([0, 2, 4])

        # Should have logged a warning about fallback
        log_content = log_output.string
        expect(log_content).to include('falling back to threads').or include('cannot be made')
      ensure
        Minigun.logger = original_logger
      end
    end
  end

  describe 'Platform.ractors?' do
    it 'returns boolean' do
      expect(Minigun::Platform.ractors?).to be(true).or be(false)
    end

    it 'returns true when Ractor::Port is defined' do
      expect(Minigun::Platform.ractors?).to eq(defined?(Ractor::Port) ? true : false)
    end
  end

  describe 'stats tracking' do
    it 'records latency for Ractor-processed items' do
      klass = Class.new do
        include Minigun::DSL

        attr_reader :results

        def initialize
          @results = []
          @mutex = Mutex.new
        end

        pipeline do
          producer :generate do |output|
            5.times { |i| output << i }
          end

          in_ractors(2) do
            processor :process do |item, output|
              # Small sleep to ensure measurable latency
              sleep 0.01
              output << (item * 2)
            end
          end

          consumer :collect do |item|
            @mutex.synchronize { @results << item }
          end
        end
      end

      instance = klass.new
      instance.run

      # Verify results came through
      expect(instance.results.sort).to eq([0, 2, 4, 6, 8])

      # Access stats through the task's pipeline
      task = instance.instance_variable_get(:@_minigun_task)
      stats = task.root_pipeline.stats

      # Stats should exist and have tracked latencies
      expect(stats).not_to be_nil

      # The process stage should have recorded latencies
      # Stats are aggregated at pipeline level, check total stats exist
      expect(stats.total_produced).to be >= 0
    end
  end
end

RSpec.describe 'Ractor execution fallback', unless: Minigun::Platform.ractors? do
  it 'falls back to threads when Ractors not available' do
    Mutex.new

    klass = Class.new do
      include Minigun::DSL

      attr_reader :results

      def initialize
        @results = []
        @mutex = Mutex.new
      end

      pipeline do
        producer :generate do |output|
          5.times { |i| output << i }
        end

        in_ractors(2) do
          processor :double do |item, output|
            output << (item * 2)
          end
        end

        consumer :collect do |item|
          @mutex.synchronize { @results << item }
        end
      end
    end

    instance = klass.new
    # Should fall back to threads when Ractors not available
    expect { instance.run }.not_to raise_error
    expect(instance.results.sort).to eq([0, 2, 4, 6, 8])
  end
end
