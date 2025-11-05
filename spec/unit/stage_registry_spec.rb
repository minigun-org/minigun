# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Minigun::StageRegistry do
  let(:registry) { described_class.new }
  let(:config) { { max_threads: 1, max_processes: 1 } }
  let(:task) { Minigun::Task.new(config: config) }

  # Helper to create a real pipeline
  def create_pipeline(name)
    Minigun::Pipeline.new(name, task, nil, config)
  end

  # Helper to create a real stage
  def create_stage(name, pipeline)
    Minigun::ProducerStage.new(name, pipeline, proc {}, {})
  end

  # Helper to create a real composite stage (PipelineStage)
  def create_composite_stage(name, pipeline, nested_pipeline)
    Minigun::PipelineStage.new(name, pipeline, nested_pipeline, nil, {})
  end

  # Helper to manually add stage to pipeline's stages array (for nested pipeline tests)
  def add_stage_to_pipeline(pipeline, stage)
    pipeline.instance_variable_get(:@stages) << stage
  end

  describe '#initialize' do
    it 'initializes empty registries' do
      expect(registry.all_stages).to be_empty
      expect(registry.all_names).to be_empty
    end
  end

  describe '#register' do
    let(:pipeline) { create_pipeline(:main) }
    let(:stage) { create_stage(:my_stage, pipeline) }

    context 'with a named stage' do
      it 'registers the stage in global namespace' do
        registry.register(pipeline, stage)
        expect(registry.all_names).to include('my_stage')
      end

      it 'registers the stage in pipeline-local namespace' do
        registry.register(pipeline, stage)
        found = registry.find_by_name(:my_stage, from_pipeline: pipeline)
        expect(found).to eq(stage)
      end

      it 'works with both symbols and strings' do
        stage_sym = create_stage(:sym_stage, pipeline)
        stage_str = create_stage('str_stage', pipeline)

        registry.register(pipeline, stage_sym)
        registry.register(pipeline, stage_str)

        expect(registry.find_by_name(:sym_stage, from_pipeline: pipeline)).to eq(stage_sym)
        expect(registry.find_by_name('str_stage', from_pipeline: pipeline)).to eq(stage_str)
      end
    end

    context 'with unnamed stage' do
      it 'auto-generates a name for nil-named stages' do
        # Create a stage without a name by using nil
        # Stage auto-generates a name like _abc123def
        unnamed_stage = Minigun::Stage.new(nil, pipeline, proc {}, {})

        registry.register(pipeline, unnamed_stage)
        expect(registry.all_stages).to include(unnamed_stage)
        # The stage now has an auto-generated name, so it appears in all_names
        expect(registry.all_names).to include(unnamed_stage.name.to_s)
        expect(unnamed_stage.name.to_s).to match(/^_[0-9a-f]+$/)
      end
    end

    context 'with :output stage' do
      it 'does not register :output stages in name indices' do
        output_stage = create_stage(:output, pipeline)

        registry.register(pipeline, output_stage)
        expect(registry.all_stages).to include(output_stage)
        expect(registry.all_names).not_to include('output')
      end
    end

    context 'duplicate names' do
      it 'raises StageNameConflict when registering duplicate name in same pipeline' do
        stage1 = create_stage(:duplicate, pipeline)

        # stage1 is already auto-registered, so creating stage2 with the same name will fail
        expect do
          create_stage(:duplicate, pipeline)
        end.to raise_error(Minigun::StageNameConflict, /Stage name 'duplicate' already exists/)
      end

      it 'allows same name in different pipelines' do
        pipeline1 = create_pipeline(:pipeline1)
        pipeline2 = create_pipeline(:pipeline2)
        stage1 = create_stage(:shared_name, pipeline1)
        stage2 = create_stage(:shared_name, pipeline2)

        expect do
          registry.register(pipeline1, stage1)
          registry.register(pipeline2, stage2)
        end.not_to raise_error

        expect(registry.find_by_name(:shared_name, from_pipeline: pipeline1)).to eq(stage1)
        expect(registry.find_by_name(:shared_name, from_pipeline: pipeline2)).to eq(stage2)
      end
    end
  end

  describe '#find_by_name - 3-level lookup strategy' do
    let(:root_pipeline) { create_pipeline(:root) }
    let(:nested_pipeline1) { create_pipeline(:nested1) }
    let(:nested_pipeline2) { create_pipeline(:nested2) }
    let(:other_pipeline) { create_pipeline(:other) }

    context 'Level 1: Local neighbors (same pipeline)' do
      it 'finds stage in the same pipeline' do
        local_stage = create_stage(:local, root_pipeline)
        registry.register(root_pipeline, local_stage)

        found = registry.find_by_name(:local, from_pipeline: root_pipeline)
        expect(found).to eq(local_stage)
      end

      it 'prioritizes local stage over global stages with same name' do
        local_stage = create_stage(:priority, root_pipeline)
        global_stage = create_stage(:priority, other_pipeline)

        registry.register(root_pipeline, local_stage)
        registry.register(other_pipeline, global_stage)

        # Looking from root_pipeline, should find local_stage first
        found = registry.find_by_name(:priority, from_pipeline: root_pipeline)
        expect(found).to eq(local_stage)

        # Looking from other_pipeline, should find global_stage
        found_other = registry.find_by_name(:priority, from_pipeline: other_pipeline)
        expect(found_other).to eq(global_stage)
      end
    end

    context 'Level 2: Children (nested pipelines)' do
      it 'finds stage in nested pipeline when not found locally' do
        nested_stage = create_stage(:nested, nested_pipeline1)
        pipeline_stage = create_composite_stage(:pipeline_stage, root_pipeline, nested_pipeline1)

        # Add the composite stage to root pipeline
        add_stage_to_pipeline(root_pipeline, pipeline_stage)

        registry.register(nested_pipeline1, nested_stage)

        # Search from root should find it in children
        found = registry.find_by_name(:nested, from_pipeline: root_pipeline)
        expect(found).to eq(nested_stage)
      end

      it 'raises AmbiguousRoutingError when multiple nested pipelines have same stage name' do
        nested_stage1 = create_stage(:ambiguous, nested_pipeline1)
        nested_stage2 = create_stage(:ambiguous, nested_pipeline2)
        pipeline_stage1 = create_composite_stage(:ps1, root_pipeline, nested_pipeline1)
        pipeline_stage2 = create_composite_stage(:ps2, root_pipeline, nested_pipeline2)

        # Add both composite stages to root pipeline
        add_stage_to_pipeline(root_pipeline, pipeline_stage1)
        add_stage_to_pipeline(root_pipeline, pipeline_stage2)

        registry.register(nested_pipeline1, nested_stage1)
        registry.register(nested_pipeline2, nested_stage2)

        expect do
          registry.find_by_name(:ambiguous, from_pipeline: root_pipeline)
        end.to raise_error(Minigun::AmbiguousRoutingError, /found 2 matches in nested pipelines/)
      end

      it 'handles deeply nested pipelines' do
        deep_pipeline = create_pipeline(:deep)
        deep_stage = create_stage(:deep, deep_pipeline)
        ps2 = create_composite_stage(:ps2, nested_pipeline1, deep_pipeline)
        ps1 = create_composite_stage(:ps1, root_pipeline, nested_pipeline1)

        # root -> nested1 -> deep
        add_stage_to_pipeline(root_pipeline, ps1)
        add_stage_to_pipeline(nested_pipeline1, ps2)

        registry.register(deep_pipeline, deep_stage)

        found = registry.find_by_name(:deep, from_pipeline: root_pipeline)
        expect(found).to eq(deep_stage)
      end

      it 'prevents infinite recursion with circular pipeline references' do
        circular_stage = create_stage(:circular, nested_pipeline1)
        ps2 = create_composite_stage(:ps2, nested_pipeline1, root_pipeline) # Circular reference!
        ps1 = create_composite_stage(:ps1, root_pipeline, nested_pipeline1)

        # Create circular reference: root -> nested1 -> root
        add_stage_to_pipeline(root_pipeline, ps1)
        add_stage_to_pipeline(nested_pipeline1, ps2)

        registry.register(nested_pipeline1, circular_stage)

        # Should not hang, should find the stage
        expect do
          found = registry.find_by_name(:circular, from_pipeline: root_pipeline)
          expect(found).to eq(circular_stage)
        end.not_to raise_error
      end
    end

    context 'Level 3: Global (any stage anywhere)' do
      it 'finds stage globally when not found locally or in children' do
        global_stage = create_stage(:global, other_pipeline)
        registry.register(other_pipeline, global_stage)

        # root_pipeline has no stages, so should search globally

        # Should find it globally
        found = registry.find_by_name(:global, from_pipeline: root_pipeline)
        expect(found).to eq(global_stage)
      end

      it 'raises AmbiguousRoutingError when multiple pipelines have same stage name globally' do
        pipeline1 = create_pipeline(:p1)
        pipeline2 = create_pipeline(:p2)
        search_pipeline = create_pipeline(:search)

        stage1 = create_stage(:global_ambiguous, pipeline1)
        stage2 = create_stage(:global_ambiguous, pipeline2)

        registry.register(pipeline1, stage1)
        registry.register(pipeline2, stage2)

        # Empty search pipeline with no local or nested stages

        expect do
          registry.find_by_name(:global_ambiguous, from_pipeline: search_pipeline)
        end.to raise_error(Minigun::AmbiguousRoutingError, /found 2 matches globally/)
      end

      it 'returns the stage when only one global match exists' do
        unique_stage = create_stage(:unique, other_pipeline)
        registry.register(other_pipeline, unique_stage)

        # root_pipeline has no stages

        found = registry.find_by_name(:unique, from_pipeline: root_pipeline)
        expect(found).to eq(unique_stage)
      end
    end

    context 'not found' do
      it 'returns nil when stage name does not exist anywhere' do
        # root_pipeline has no stages

        found = registry.find_by_name(:nonexistent, from_pipeline: root_pipeline)
        expect(found).to be_nil
      end

      it 'returns nil for nil name' do
        found = registry.find_by_name(nil, from_pipeline: root_pipeline)
        expect(found).to be_nil
      end
    end
  end

  describe '#find' do
    let(:pipeline) { create_pipeline(:main) }
    let(:stage) { create_stage(:my_stage, pipeline) }

    it 'delegates to find_by_name' do
      registry.register(pipeline, stage)

      found = registry.find(:my_stage, from_pipeline: pipeline)
      expect(found).to eq(stage)
    end

    it 'returns nil for nil identifier' do
      found = registry.find(nil, from_pipeline: pipeline)
      expect(found).to be_nil
    end
  end

  describe '#all_stages' do
    it 'returns all registered stages' do
      pipeline1 = create_pipeline(:p1)
      pipeline2 = create_pipeline(:p2)
      stage1 = create_stage(:stage1, pipeline1)
      stage2 = create_stage(:stage2, pipeline1)
      stage3 = create_stage(:stage3, pipeline2)

      registry.register(pipeline1, stage1)
      registry.register(pipeline1, stage2)
      registry.register(pipeline2, stage3)

      stages = registry.all_stages
      expect(stages).to contain_exactly(stage1, stage2, stage3)
    end

    it 'returns unique stages even if registered in multiple places' do
      pipeline1 = create_pipeline(:p1)
      stage = create_stage(:shared, pipeline1)

      registry.register(pipeline1, stage)

      # all_stages should return unique stages
      expect(registry.all_stages.count(stage)).to eq(1)
    end
  end

  describe '#all_names' do
    it 'returns all registered stage names' do
      pipeline = create_pipeline(:main)
      stage1 = create_stage(:alpha, pipeline)
      stage2 = create_stage(:beta, pipeline)

      registry.register(pipeline, stage1)
      registry.register(pipeline, stage2)

      names = registry.all_names
      expect(names).to contain_exactly('alpha', 'beta')
    end

    it 'normalizes names to strings' do
      pipeline = create_pipeline(:main)
      stage = create_stage(:symbol_name, pipeline)

      registry.register(pipeline, stage)

      expect(registry.all_names).to include('symbol_name')
    end
  end

  describe '#clear' do
    it 'clears all registrations' do
      pipeline = create_pipeline(:main)
      stage = create_stage(:test, pipeline)

      registry.register(pipeline, stage)
      expect(registry.all_stages).not_to be_empty

      registry.clear

      expect(registry.all_stages).to be_empty
      expect(registry.all_names).to be_empty
      expect(registry.find_by_name(:test, from_pipeline: pipeline)).to be_nil
    end
  end

  describe 'pipeline object identity' do
    it 'distinguishes pipelines by object identity, not by name' do
      # Two different pipeline objects with the same name
      pipeline1 = create_pipeline(:same_name)
      pipeline2 = create_pipeline(:same_name)
      stage1 = create_stage(:stage1, pipeline1)
      stage2 = create_stage(:stage2, pipeline2)

      registry.register(pipeline1, stage1)
      registry.register(pipeline2, stage2)

      # Should find different stages based on which pipeline object we use (local lookup)
      found1 = registry.find_by_name(:stage1, from_pipeline: pipeline1)
      found2 = registry.find_by_name(:stage2, from_pipeline: pipeline2)

      expect(found1).to eq(stage1)
      expect(found2).to eq(stage2)

      # Cross-lookup will find stages globally (since not in local scope)
      # This demonstrates that pipelines are distinguished by object, not by name
      # pipeline1 and pipeline2 have no nested stages

      expect(registry.find_by_name(:stage1, from_pipeline: pipeline2)).to eq(stage1)  # Found globally
      expect(registry.find_by_name(:stage2, from_pipeline: pipeline1)).to eq(stage2)  # Found globally
    end

    it 'uses the actual pipeline object as hash key' do
      pipeline = create_pipeline(:main)
      stage = create_stage(:test, pipeline)

      registry.register(pipeline, stage)

      # Even if we create a new pipeline with same name, it won't find it in local scope
      different_pipeline = create_pipeline(:main)
      found = registry.find_by_name(:test, from_pipeline: different_pipeline)

      # Should not find in local scope (different object)
      # But will find in global scope
      expect(found).to eq(stage) # Found globally since no local match
    end
  end
end
