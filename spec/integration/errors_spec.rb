# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Error Handling' do
  before do
    allow(Minigun.logger).to receive(:info)
  end

  describe 'Error handling in consumer' do
    let(:pipeline_class) do
      Class.new do
        include Minigun::DSL

        attr_accessor :results, :errors

        def initialize
          @results = []
          @errors = []
        end

        pipeline do
          producer :generate do |output|
            5.times { |i| output << i }
          end

          consumer :process do |item|
            if item == 2
              # Simulate error but don't raise to keep test running
              errors << "Error on item #{item}"
            else
              results << item
            end
          end
        end
      end
    end

    it 'continues processing after errors in consumer' do
      task = pipeline_class.new
      task.run

      expect(task.results).to include(0, 1, 3, 4)
      expect(task.errors.size).to eq(1)
    end
  end

  describe 'Error: stage references non-existent target' do
    let(:pipeline_class) do
      Class.new do
        include Minigun::DSL

        pipeline do
          producer :generate, to: :nonexistent do |output|
            output << 1
          end
        end
      end
    end

    it 'raises UnresolvedReference for non-existent stage' do
      pipeline = pipeline_class.new

      expect { pipeline.run }.to raise_error(Minigun::Errors::UnresolvedReference) do |error|
        expect(error.reference).to eq(:nonexistent)
      end
    end
  end

  describe 'Errors::StageNameConflict' do
    it 'is raised when defining duplicate stage names in same pipeline' do
      klass = Class.new do
        include Minigun::DSL

        pipeline do
          producer :source do |output|
            output << 1
          end

          processor :duplicate do |item, output|
            output << item
          end

          processor :duplicate do |item, output|
            output << item
          end
        end
      end

      expect do
        klass.new.run
      end.to raise_error(Minigun::Errors::StageNameConflict) do |error|
        expect(error.stage_name).to eq(:duplicate)
      end
    end
  end

  describe 'Errors::AmbiguousRouting' do
    it 'is raised when resolving ambiguous stage name in registry' do
      # Test StageRegistry directly with mock objects
      registry = Minigun::StageRegistry.new

      # Create mock pipelines and stages
      parent_pipeline = double('parent_pipeline', name: 'root', stages: [])
      nested_pipeline_a = double('nested_pipeline_a', name: 'pipeline_a', stages: [])
      nested_pipeline_b = double('nested_pipeline_b', name: 'pipeline_b', stages: [])

      stage_a = double('stage_a', name: :transform, run_mode: :reactive)
      stage_b = double('stage_b', name: :transform, run_mode: :reactive)

      # Register stages with same name in different pipelines
      registry.register(nested_pipeline_a, stage_a)
      registry.register(nested_pipeline_b, stage_b)

      # When looking globally, should find ambiguous match
      expect do
        registry.find_by_name(:transform, from_pipeline: parent_pipeline)
      end.to raise_error(Minigun::Errors::AmbiguousRouting) do |error|
        expect(error.stage_name).to eq(:transform)
        expect(error.candidates.size).to eq(2)
      end
    end
  end

  describe 'Errors::CyclicDependency' do
    it 'is raised when adding an edge that creates a cycle' do
      dag = Minigun::DAG.new

      stage_a = double('stage_a', name: :a)
      stage_b = double('stage_b', name: :b)
      stage_c = double('stage_c', name: :c)

      dag.add_edge(stage_a, stage_b)
      dag.add_edge(stage_b, stage_c)

      expect do
        dag.add_edge(stage_c, stage_a)
      end.to raise_error(Minigun::Errors::CyclicDependency) do |error|
        expect(error.from_stage).to eq(stage_c)
        expect(error.to_stage).to eq(stage_a)
      end
    end
  end

  describe 'Errors::InvalidOption' do
    it 'is raised for invalid stage type' do
      task = Minigun::Task.new
      pipeline = task.root_pipeline

      expect do
        pipeline.add_stage(:invalid_type, :test_stage)
      end.to raise_error(Minigun::Errors::InvalidOption) do |error|
        expect(error.option_name).to eq(:stage_type)
        expect(error.value).to eq(:invalid_type)
      end
    end

    it 'is raised for invalid restart_policy' do
      expect do
        Minigun::Execution::WorkerMonitor.new(
          restart_policy: :invalid_policy,
          max_restarts: 3,
          restart_window: 60
        )
      end.to raise_error(Minigun::Errors::InvalidOption) do |error|
        expect(error.option_name).to eq(:restart_policy)
        expect(error.value).to eq(:invalid_policy)
      end
    end

    it 'is raised for invalid delivery_mode in cluster' do
      klass = Class.new do
        include Minigun::DSL

        pipeline do
          in_cluster(worker_uris: ['druby://localhost:9000'], delivery_mode: :invalid) do
            processor :work do |item, output|
              output << item
            end
          end
        end
      end

      expect do
        klass.new.run
      end.to raise_error(Minigun::Errors::InvalidOption) do |error|
        expect(error.option_name).to eq(:delivery_mode)
        expect(error.value).to eq(:invalid)
      end
    end

    it 'is raised when in_cluster has neither coordinator_uri nor worker_uris' do
      klass = Class.new do
        include Minigun::DSL

        pipeline do
          in_cluster do
            processor :work do |item, output|
              output << item
            end
          end
        end
      end

      expect do
        klass.new.run
      end.to raise_error(Minigun::Errors::InvalidOption) do |error|
        expect(error.option_name).to eq(:in_cluster)
      end
    end

    it 'is raised when in_cluster has both coordinator_uri and worker_uris' do
      klass = Class.new do
        include Minigun::DSL

        pipeline do
          in_cluster(coordinator_uri: 'druby://localhost:9000', worker_uris: ['druby://localhost:9001']) do
            processor :work do |item, output|
              output << item
            end
          end
        end
      end

      expect do
        klass.new.run
      end.to raise_error(Minigun::Errors::InvalidOption) do |error|
        expect(error.option_name).to eq(:in_cluster)
      end
    end

    it 'is raised for invalid produce_each source' do
      klass = Class.new do
        include Minigun::DSL

        pipeline do
          produce_each :source, 'not_an_enumerable'
        end
      end

      expect do
        klass.new.run
      end.to raise_error(Minigun::Errors::InvalidOption) do |error|
        expect(error.option_name).to eq(:source)
      end
    end
  end

  describe 'Errors::InvalidOption for executor type' do
    it 'is raised for unknown executor type' do
      stage_ctx = double('stage_ctx')

      expect do
        Minigun::Execution.create_executor(:unknown_executor, stage_ctx)
      end.to raise_error(Minigun::Errors::InvalidOption) do |error|
        expect(error.option_name).to eq(:executor_type)
        expect(error.value).to eq(:unknown_executor)
      end
    end
  end

  describe 'Cluster errors' do
    describe 'Minigun::Errors::ClusterWorkerNotFound' do
      it 'is raised when worker has no processor for stage' do
        worker = Minigun::Cluster::Worker.new(
          coordinator_uri: 'druby://localhost:9000',
          worker_id: 'test-worker'
        )

        expect do
          worker.process_item_sync(:missing_stage, { id: 1 })
        end.to raise_error(Minigun::Errors::ClusterWorkerNotFound) do |error|
          expect(error.stage_name).to eq(:missing_stage)
        end
      end
    end
  end
end
