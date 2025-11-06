# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Minigun::PipelineStage do
  let(:config) { { max_threads: 2, max_processes: 1 } }
  let(:task) { Minigun::Task.new(config: config) }
  let(:pipeline) { task.root_pipeline }
  let(:context) { Object.new }

  before do
    # Initialize runtime_edges for tests that don't call run()
    pipeline.instance_variable_set(:@runtime_edges, Concurrent::Hash.new { |h, k| h[k] = Concurrent::Set.new })
  end

  describe '#initialize' do
    it 'creates a PipelineStage with a nested pipeline' do
      nested = Minigun::Pipeline.new(:nested, task, pipeline, config)
      stage = described_class.new(:my_pipeline, pipeline, nested, {})
      expect(stage.name).to eq(:my_pipeline)
      expect(stage.nested_pipeline).to eq(nested)
    end
  end

  describe '#run_mode' do
    it 'returns :composite' do
      nested = Minigun::Pipeline.new(:nested, task, pipeline, config)
      stage = described_class.new(:my_pipeline, pipeline, nested, {})
      expect(stage.run_mode).to eq(:composite)
    end
  end

  describe '#run_stage' do
    it 'returns early if no pipeline is set' do
      stage = described_class.new(:my_pipeline, pipeline, nil, {})
      stage_ctx = Minigun::StageContext.new(
        stage: stage,
        dag: pipeline.dag,
        runtime_edges: pipeline.runtime_edges,
        stage_stats: nil,
        worker: nil,
        input_queue: Queue.new,
        sources_expected: Set.new,
        sources_done: Set.new
      )

      # Should not raise, just return
      expect { stage.run_stage(stage_ctx) }.not_to raise_error
    end

    it 'runs the nested pipeline when pipeline is set' do
      # Set context on the root pipeline, as that's where run gets it from
      pipeline.instance_variable_set(:@context, context)

      nested_pipeline = Minigun::Pipeline.new(:nested, task, pipeline, config)

      stage = described_class.new(:my_pipeline, pipeline, nested_pipeline, {})
      stage_ctx = Minigun::StageContext.new(
        stage: stage,
        dag: pipeline.dag,
        runtime_edges: pipeline.runtime_edges,
        stage_stats: nil,
        worker: nil,
        input_queue: Queue.new,
        sources_expected: Set.new,
        sources_done: Set.new
      )

      # Track whether nested_pipeline.run was called with correct context
      run_called = false
      allow(nested_pipeline).to receive(:run) do |ctx|
        run_called = true
        expect(ctx).to eq(context)
      end

      stage.run_stage(stage_ctx)
      expect(run_called).to be true
    end

    it 'sets input_queues when stage has upstream sources' do
      nested_pipeline = Minigun::Pipeline.new(:nested, task, pipeline, config)
      nested_pipeline.instance_variable_set(:@context, context)

      stage = described_class.new(:my_pipeline, pipeline, nested_pipeline, {})

      input_queue = Queue.new
      upstream_stage = Minigun::ProducerStage.new(:upstream, pipeline, proc {}, {})
      sources = Set.new([upstream_stage])

      stage_ctx = Minigun::StageContext.new(
        stage: stage,
        dag: pipeline.dag,
        runtime_edges: pipeline.runtime_edges,
        stage_stats: nil,
        worker: nil,
        input_queue: input_queue,
        sources_expected: sources,
        sources_done: Set.new
      )

      allow(nested_pipeline).to receive(:run)

      stage.run_stage(stage_ctx)

      # Verify input_queues was set on the nested pipeline with sources_expected
      input_queues = nested_pipeline.instance_variable_get(:@input_queues)
      expect(input_queues[:input]).to eq(input_queue)
      expect(input_queues[:sources_expected]).to eq(sources)
    end

    it 'always sets output_queues' do
      nested_pipeline = Minigun::Pipeline.new(:nested, task, pipeline, config)
      nested_pipeline.instance_variable_set(:@context, context)

      stage = described_class.new(:my_pipeline, pipeline, nested_pipeline, {})

      stage_ctx = Minigun::StageContext.new(
        stage: stage,
        dag: pipeline.dag,
        runtime_edges: pipeline.runtime_edges,
        stage_stats: nil,
        worker: nil,
        input_queue: Queue.new,
        sources_expected: Set.new,
        sources_done: Set.new
      )

      allow(nested_pipeline).to receive(:run)

      stage.run_stage(stage_ctx)

      # Verify output_queues was set on the nested pipeline
      output_queues = nested_pipeline.instance_variable_get(:@output_queues)
      expect(output_queues).to have_key(:output)
      expect(output_queues[:output]).to be_a(Minigun::OutputQueue)
    end

    it 'sends end signals to downstream stages after pipeline completes' do
      nested_pipeline = Minigun::Pipeline.new(:nested, task, pipeline, config)
      nested_pipeline.instance_variable_set(:@context, context)

      stage = described_class.new(:my_pipeline, pipeline, nested_pipeline, {})

      # Create a downstream stage to receive signals
      downstream_stage = Minigun::ProducerStage.new(:downstream, pipeline, proc {}, {})
      pipeline.dag.add_edge(stage, downstream_stage)

      stage_ctx = Minigun::StageContext.new(
        stage: stage,
        dag: pipeline.dag,
        runtime_edges: pipeline.runtime_edges,
        stage_stats: nil,
        worker: nil,
        input_queue: Queue.new,
        sources_expected: Set.new,
        sources_done: Set.new
      )

      allow(nested_pipeline).to receive(:run)

      # Track if send_end_signals is called
      send_end_signals_called = false
      allow(stage).to receive(:send_end_signals) do |ctx|
        send_end_signals_called = true
        expect(ctx).to eq(stage_ctx)
      end

      stage.run_stage(stage_ctx)
      expect(send_end_signals_called).to be true
    end

    it 'sends end signals even if pipeline raises an error' do
      nested_pipeline = Minigun::Pipeline.new(:nested, task, pipeline, config)
      nested_pipeline.instance_variable_set(:@context, context)

      stage = described_class.new(:my_pipeline, pipeline, nested_pipeline, {})

      stage_ctx = Minigun::StageContext.new(
        stage: stage,
        dag: pipeline.dag,
        runtime_edges: pipeline.runtime_edges,
        stage_stats: nil,
        worker: nil,
        input_queue: Queue.new,
        sources_expected: Set.new,
        sources_done: Set.new
      )

      allow(nested_pipeline).to receive(:run).and_raise(StandardError, 'test error')

      # Track if send_end_signals is called even on error
      send_end_signals_called = false
      allow(stage).to receive(:send_end_signals) do |ctx|
        send_end_signals_called = true
        expect(ctx).to eq(stage_ctx)
      end

      expect { stage.run_stage(stage_ctx) }.to raise_error(StandardError, 'test error')
      expect(send_end_signals_called).to be true
    end
  end
end
