# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Minigun::Execution::ExecutionPlan do
  let(:dag) { Minigun::DAG.new }
  let(:config) { { max_threads: 5, max_processes: 2, default_context: :thread } }
  let(:stages) { {} }
  let(:plan) { described_class.new(dag, stages, config) }

  describe '#plan!' do
    it 'assigns contexts to all stages' do
      # Create simple pipeline: producer -> processor -> consumer
      producer = Minigun::AtomicStage.new(name: :source, block: proc { emit(1) })
      processor = Minigun::AtomicStage.new(name: :double, block: proc { |i| emit(i * 2) })
      consumer = Minigun::AtomicStage.new(name: :sink, block: proc { |i| i })

      stages[:source] = producer
      stages[:double] = processor
      stages[:sink] = consumer

      dag.add_node(:source)
      dag.add_node(:double)
      dag.add_node(:sink)
      dag.add_edge(:source, :double)
      dag.add_edge(:double, :sink)

      plan.plan!

      expect(plan.context_for(:source)).to eq(:thread)
      expect(plan.context_for(:double)).to eq(:thread)
      expect(plan.context_for(:sink)).to eq(:thread)
    end

    it 'identifies producers correctly' do
      producer = Minigun::AtomicStage.new(name: :source, block: proc { emit(1) })
      stages[:source] = producer
      dag.add_node(:source)

      plan.plan!

      # Producers get their own context
      expect(plan.affinity_for(:source)).to be_nil
    end

    it 'colocates stages with single upstream' do
      producer = Minigun::AtomicStage.new(name: :source, block: proc { emit(1) })
      processor = Minigun::AtomicStage.new(name: :double, block: proc { |i| emit(i * 2) })

      stages[:source] = producer
      stages[:double] = processor

      dag.add_node(:source)
      dag.add_node(:double)
      dag.add_edge(:source, :double)

      plan.plan!

      # double should be colocated with source
      expect(plan.affinity_for(:double)).to eq(:source)
      expect(plan.colocated?(:double, :source)).to be true
    end

    it 'does not colocate stages with multiple upstream' do
      prod1 = Minigun::AtomicStage.new(name: :source1, block: proc { emit(1) })
      prod2 = Minigun::AtomicStage.new(name: :source2, block: proc { emit(2) })
      consumer = Minigun::AtomicStage.new(name: :sink, block: proc { |i| i })

      stages[:source1] = prod1
      stages[:source2] = prod2
      stages[:sink] = consumer

      dag.add_node(:source1)
      dag.add_node(:source2)
      dag.add_node(:sink)
      dag.add_edge(:source1, :sink)
      dag.add_edge(:source2, :sink)

      plan.plan!

      # sink has multiple upstream, should be independent
      expect(plan.affinity_for(:sink)).to be_nil
    end

    it 'does not colocate with accumulator stages' do
      producer = Minigun::AtomicStage.new(name: :source, block: proc { emit(1) })
      accumulator = Minigun::AccumulatorStage.new(name: :batch, options: { max_size: 10 })
      consumer = Minigun::AtomicStage.new(name: :sink, block: proc { |i| i })

      stages[:source] = producer
      stages[:batch] = accumulator
      stages[:sink] = consumer

      dag.add_node(:source)
      dag.add_node(:batch)
      dag.add_node(:sink)
      dag.add_edge(:source, :batch)
      dag.add_edge(:batch, :sink)

      plan.plan!

      # sink should NOT be colocated with accumulator
      expect(plan.affinity_for(:sink)).to be_nil
    end

    it 'respects explicit execution context on stages' do
      producer = Minigun::AtomicStage.new(name: :source, block: proc { emit(1) })
      processor = Minigun::AtomicStage.new(
        name: :heavy,
        block: proc { |i| emit(i * 2) },
        options: { _execution_context: { type: :processes, mode: :pool, pool_size: 2 } }
      )

      stages[:source] = producer
      stages[:heavy] = processor

      dag.add_node(:source)
      dag.add_node(:heavy)
      dag.add_edge(:source, :heavy)

      plan.plan!

      # heavy has explicit execution context
      expect(plan.context_for(:heavy)).to eq(:processes)
      # Should NOT be colocated due to explicit execution context
      expect(plan.affinity_for(:heavy)).to be_nil
    end
  end

  describe '#context_for' do
    it 'returns thread as default for unknown stages' do
      expect(plan.context_for(:unknown)).to eq(:thread)
    end

    it 'returns assigned context after planning' do
      producer = Minigun::AtomicStage.new(
        name: :source,
        block: proc { emit(1) },
        options: { _execution_context: { type: :ractors, mode: :pool, pool_size: 4 } }
      )
      stages[:source] = producer
      dag.add_node(:source)

      plan.plan!

      expect(plan.context_for(:source)).to eq(:ractors)
    end
  end

  describe '#context_types' do
    it 'returns unique context types used' do
      prod1 = Minigun::AtomicStage.new(
        name: :source1,
        block: proc { emit(1) },
        options: { _execution_context: { type: :threads, mode: :pool, pool_size: 5 } }
      )
      prod2 = Minigun::AtomicStage.new(
        name: :source2,
        block: proc { emit(2) },
        options: { _execution_context: { type: :processes, mode: :pool, pool_size: 2 } }
      )
      prod3 = Minigun::AtomicStage.new(
        name: :source3,
        block: proc { emit(3) },
        options: { _execution_context: { type: :threads, mode: :pool, pool_size: 5 } }
      )

      stages[:source1] = prod1
      stages[:source2] = prod2
      stages[:source3] = prod3

      dag.add_node(:source1)
      dag.add_node(:source2)
      dag.add_node(:source3)

      plan.plan!

      types = plan.context_types
      expect(types).to include(:threads, :processes)
      expect(types.size).to eq(2)
    end
  end

  describe '#affinity_groups' do
    it 'groups stages by affinity' do
      prod = Minigun::AtomicStage.new(name: :source, block: proc { emit(1) })
      proc1 = Minigun::AtomicStage.new(name: :double, block: proc { |i| emit(i * 2) })
      proc2 = Minigun::AtomicStage.new(name: :triple, block: proc { |i| emit(i * 3) })
      cons = Minigun::AtomicStage.new(name: :sink, block: proc { |i| i })

      stages[:source] = prod
      stages[:double] = proc1
      stages[:triple] = proc2
      stages[:sink] = cons

      dag.add_node(:source)
      dag.add_node(:double)
      dag.add_node(:triple)
      dag.add_node(:sink)
      dag.add_edge(:source, :double)
      dag.add_edge(:double, :triple)
      dag.add_edge(:triple, :sink)

      plan.plan!

      groups = plan.affinity_groups

      # source has no affinity (nil group)
      expect(groups[nil]).to include(:source)

      # double colocated with source
      expect(groups[:source]).to include(:double)

      # triple colocated with double
      expect(groups[:double]).to include(:triple)

      # sink colocated with triple
      expect(groups[:triple]).to include(:sink)
    end
  end

  describe '#independent_stages' do
    it 'returns stages with no affinity' do
      prod1 = Minigun::AtomicStage.new(name: :source1, block: proc { emit(1) })
      prod2 = Minigun::AtomicStage.new(name: :source2, block: proc { emit(2) })

      stages[:source1] = prod1
      stages[:source2] = prod2

      dag.add_node(:source1)
      dag.add_node(:source2)

      plan.plan!

      independent = plan.independent_stages
      expect(independent).to contain_exactly(:source1, :source2)
    end
  end

  describe '#colocated_stages' do
    it 'returns stages grouped by their affinity parent' do
      prod = Minigun::AtomicStage.new(name: :source, block: proc { emit(1) })
      proc1 = Minigun::AtomicStage.new(name: :double, block: proc { |i| emit(i * 2) })
      proc2 = Minigun::AtomicStage.new(name: :add_one, block: proc { |i| emit(i + 1) })

      stages[:source] = prod
      stages[:double] = proc1
      stages[:add_one] = proc2

      dag.add_node(:source)
      dag.add_node(:double)
      dag.add_node(:add_one)
      dag.add_edge(:source, :double)
      dag.add_edge(:double, :add_one)

      plan.plan!

      colocated = plan.colocated_stages

      expect(colocated[:source]).to include(:double)
      expect(colocated[:double]).to include(:add_one)
    end
  end

  describe 'execution context mapping' do
    it 'maps thread execution context' do
      stage = Minigun::AtomicStage.new(
        name: :test,
        block: proc {},
        options: { _execution_context: { type: :threads, mode: :pool, pool_size: 5 } }
      )
      stages[:test] = stage
      dag.add_node(:test)

      plan.plan!

      expect(plan.context_for(:test)).to eq(:threads)
    end

    it 'maps process execution context' do
      stage = Minigun::AtomicStage.new(
        name: :test,
        block: proc {},
        options: { _execution_context: { type: :processes, mode: :per_batch, max: 2 } }
      )
      stages[:test] = stage
      dag.add_node(:test)

      plan.plan!

      expect(plan.context_for(:test)).to eq(:processes)
    end

    it 'maps ractor execution context' do
      stage = Minigun::AtomicStage.new(
        name: :test,
        block: proc {},
        options: { _execution_context: { type: :ractors, mode: :pool, pool_size: 4 } }
      )
      stages[:test] = stage
      dag.add_node(:test)

      plan.plan!

      expect(plan.context_for(:test)).to eq(:ractors)
    end

    it 'maps different execution context types' do
      thread_stage = Minigun::AtomicStage.new(
        name: :st,
        block: proc {},
        options: { _execution_context: { type: :threads, mode: :pool, pool_size: 5 } }
      )
      process_stage = Minigun::AtomicStage.new(
        name: :sf,
        block: proc {},
        options: { _execution_context: { type: :processes, mode: :per_batch, max: 2 } }
      )
      ractor_stage = Minigun::AtomicStage.new(
        name: :sr,
        block: proc {},
        options: { _execution_context: { type: :ractors, mode: :pool, pool_size: 4 } }
      )

      stages[:st] = thread_stage
      stages[:sf] = process_stage
      stages[:sr] = ractor_stage

      dag.add_node(:st)
      dag.add_node(:sf)
      dag.add_node(:sr)

      plan.plan!

      expect(plan.context_for(:st)).to eq(:threads)
      expect(plan.context_for(:sf)).to eq(:processes)
      expect(plan.context_for(:sr)).to eq(:ractors)
    end
  end

  describe 'PipelineStage handling' do
    it 'does not colocate with PipelineStages' do
      pipeline_stage = Minigun::PipelineStage.new(name: :nested)
      processor = Minigun::AtomicStage.new(name: :process, block: proc { |i| emit(i * 2) })

      stages[:nested] = pipeline_stage
      stages[:process] = processor

      dag.add_node(:nested)
      dag.add_node(:process)
      dag.add_edge(:nested, :process)

      plan.plan!

      # Should NOT be colocated with PipelineStage
      expect(plan.affinity_for(:process)).to be_nil
    end
  end
end

