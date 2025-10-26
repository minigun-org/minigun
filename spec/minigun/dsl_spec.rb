# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Minigun::DSL do
  describe 'class methods' do
    let(:test_class) do
      Class.new do
        include Minigun::DSL
      end
    end

    it 'provides max_threads configuration' do
      test_class.max_threads 10
      expect(test_class._minigun_task.config[:max_threads]).to eq(10)
    end

    it 'provides max_processes configuration' do
      test_class.max_processes 4
      expect(test_class._minigun_task.config[:max_processes]).to eq(4)
    end

    it 'provides max_retries configuration' do
      test_class.max_retries 5
      expect(test_class._minigun_task.config[:max_retries]).to eq(5)
    end

    it 'raises error when defining a producer without pipeline do' do
      expect {
        test_class.producer(:test_producer) { "producer code" }
      }.to raise_error(NoMethodError, /Stage definitions must be inside 'pipeline do' block/)
    end

    it 'raises error when defining processors without pipeline do' do
      expect {
        test_class.processor(:test_processor) { |x| x }
      }.to raise_error(NoMethodError, /Stage definitions must be inside 'pipeline do' block/)
    end

    it 'raises error when defining an accumulator without pipeline do' do
      expect {
        test_class.accumulator(:test_accumulator) { "accumulator code" }
      }.to raise_error(NoMethodError, /Stage definitions must be inside 'pipeline do' block/)
    end

    it 'raises error when defining a consumer without pipeline do' do
      expect {
        test_class.consumer(:test_consumer) { |x| x }
      }.to raise_error(NoMethodError, /Stage definitions must be inside 'pipeline do' block/)
    end

    it 'allows defining before_run hook inside pipeline do' do
      test_class.pipeline do
        before_run { "before run" }
      end
      instance = test_class.new
      instance.run rescue nil  # Trigger evaluation
      expect(test_class._minigun_task.hooks[:before_run]).not_to be_empty
    end

    it 'allows defining after_run hook inside pipeline do' do
      test_class.pipeline do
        after_run { "after run" }
      end
      instance = test_class.new
      instance.run rescue nil  # Trigger evaluation
      expect(test_class._minigun_task.hooks[:after_run]).not_to be_empty
    end

    it 'allows defining before_fork hook inside pipeline do' do
      test_class.pipeline do
        before_fork { "before fork" }
      end
      instance = test_class.new
      instance.run rescue nil  # Trigger evaluation
      expect(test_class._minigun_task.hooks[:before_fork]).not_to be_empty
    end

    it 'allows defining after_fork hook inside pipeline do' do
      test_class.pipeline do
        after_fork { "after fork" }
      end
      instance = test_class.new
      instance.run rescue nil  # Trigger evaluation
      expect(test_class._minigun_task.hooks[:after_fork]).not_to be_empty
    end

    it 'allows defining pipeline block for grouping' do
      test_class.pipeline do
        producer(:grouped_producer) { "code" }
        consumer(:grouped_consumer) { |x| x }
      end

      # Need to instantiate and run to trigger evaluation
      instance = test_class.new
      instance.run rescue nil

      producer = test_class._minigun_task.stages[:grouped_producer]
      consumer = test_class._minigun_task.stages[:grouped_consumer]

      expect(producer).not_to be_nil
      expect(producer.name).to eq(:grouped_producer)
      expect(consumer).not_to be_nil
      expect(consumer.name).to eq(:grouped_consumer)
    end
  end

  describe 'instance methods' do
    let(:test_class) do
      Class.new do
        include Minigun::DSL

        pipeline do
          producer(:test_producer) do
            5.times { |i| emit(i) }
          end

          consumer(:test_consumer) do |item|
            @processed ||= []
            @processed << item
          end
        end
      end
    end

    let(:instance) { test_class.new }

    it 'provides run method' do
      expect(instance).to respond_to(:run)
    end

    it 'provides go_brrr! alias' do
      expect(instance).to respond_to(:go_brrr!)
    end
  end

  describe 'full pipeline definition' do
    let(:test_class) do
      Class.new do
        include Minigun::DSL

        max_threads 3
        max_processes 2

        pipeline do
          before_run { @start_time = Time.now }
          after_run { @end_time = Time.now }

          producer :generate do
            3.times { |i| emit(i + 1) }
          end

          processor :double do |num|
            emit(num * 2)
          end

          consumer :collect do |num|
            @results ||= []
            @results << num
          end
        end

        def initialize
          @start_time = nil
          @end_time = nil
        end
      end
    end

    it 'correctly configures all components' do
      # Need to instantiate to trigger pipeline evaluation
      instance = test_class.new
      instance.run rescue nil  # Trigger evaluation
      task = test_class._minigun_task
      pipeline = task.root_pipeline

      expect(task.config[:max_threads]).to eq(3)
      expect(task.config[:max_processes]).to eq(2)

      # Check that stages were added by name
      expect(pipeline.stages[:generate]).not_to be_nil
      expect(pipeline.stages[:double]).not_to be_nil
      expect(pipeline.stages[:collect]).not_to be_nil

      # Verify stage properties based on their characteristics
      gen_stage = pipeline.stages[:generate]
      double_stage = pipeline.stages[:double]
      collect_stage = pipeline.stages[:collect]

      expect(gen_stage.producer?).to be true
      expect(double_stage.producer?).to be false
      expect(double_stage.accumulator?).to be false
      expect(collect_stage.producer?).to be false

      # Verify we have 3 stages total
      expect(pipeline.stages.size).to eq(3)
      expect(task.hooks[:before_run].size).to eq(1)
      expect(task.hooks[:after_run].size).to eq(1)
    end
  end

  describe 'pipeline do wrapper requirement' do
    before do
      allow(Minigun.logger).to receive(:info)
    end

    it 'raises error when defining stages without pipeline block wrapper' do
      # Attempting to define pipeline WITHOUT explicit pipeline block should error
      expect {
        Class.new do
          include Minigun::DSL

          # No pipeline do...end wrapper - should raise error!
          producer :generate do
            3.times { |i| emit(i + 1) }
          end
        end
      }.to raise_error(NoMethodError, /Stage definitions must be inside 'pipeline do' block/)
    end

    it 'works correctly with pipeline block' do
      # WITH pipeline block - should work
      with_block = Class.new do
        include Minigun::DSL
        attr_accessor :results

        def initialize
          @results = []
        end

        pipeline do
          producer :source do
            5.times { |i| emit(i) }
          end

          consumer :sink do |num|
            results << num
          end
        end
      end

      instance = with_block.new
      instance.run

      expect(instance.results).to contain_exactly(0, 1, 2, 3, 4)
    end

    it 'OLD TEST - WITHOUT pipeline block raises error' do
      # This test documents the old behavior is no longer supported
      expect {
        Class.new do
          include Minigun::DSL
        attr_accessor :results

        def initialize
          @results = []
        end

          # Stages without pipeline do should raise error
          producer :source do
            5.times { |i| emit(i) }
          end
        end
      }.to raise_error(NoMethodError, /Stage definitions must be inside 'pipeline do' block/)
    end

    it 'requires pipeline do for all stages (mixing not allowed)' do
      # Attempting to mix styles should fail
      expect {
        Class.new do
          include Minigun::DSL

          # Stage outside pipeline block - should raise error
          producer :start do
            emit(10)
          end
        end
      }.to raise_error(NoMethodError, /Stage definitions must be inside 'pipeline do' block/)
    end

    it 'requires pipeline do for complex routing' do
      expect {
        Class.new do
          include Minigun::DSL

          # Routing without pipeline block - should raise error
          producer :start, to: [:process_a, :process_b] do
            emit(5)
          end
        end
      }.to raise_error(NoMethodError, /Stage definitions must be inside 'pipeline do' block/)
    end

    it 'requires pipeline do for all stage types' do
      expect {
        Class.new do
          include Minigun::DSL

          # Direct definition without pipeline block - should raise error
          producer :fetch do
            emit(1)
          end
        end
      }.to raise_error(NoMethodError, /Stage definitions must be inside 'pipeline do' block/)
    end
  end
end

