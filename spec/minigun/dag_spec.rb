# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Minigun::DAG do
  let(:dag) { described_class.new }

  describe '#add_node and #add_edge' do
    it 'adds nodes and edges' do
      dag.add_node(:a)
      dag.add_node(:b)
      dag.add_edge(:a, :b)

      expect(dag.nodes).to include(:a, :b)
      expect(dag.downstream(:a)).to eq([:b])
      expect(dag.upstream(:b)).to eq([:a])
    end

    it 'automatically adds nodes when adding edges' do
      dag.add_edge(:x, :y)

      expect(dag.nodes).to include(:x, :y)
    end

    it 'prevents duplicate edges' do
      dag.add_edge(:a, :b)
      dag.add_edge(:a, :b)

      expect(dag.downstream(:a)).to eq([:b])
    end
  end

  describe '#terminal? and #source?' do
    before do
      dag.add_edge(:a, :b)
      dag.add_edge(:b, :c)
    end

    it 'identifies terminal nodes' do
      expect(dag.terminal?(:c)).to be true
      expect(dag.terminal?(:b)).to be false
      expect(dag.terminal?(:a)).to be false
    end

    it 'identifies source nodes' do
      expect(dag.source?(:a)).to be true
      expect(dag.source?(:b)).to be false
      expect(dag.source?(:c)).to be false
    end
  end

  describe '#terminals and #sources' do
    before do
      dag.add_edge(:a, :b)
      dag.add_edge(:a, :c)
      dag.add_edge(:b, :d)
      dag.add_edge(:c, :d)
    end

    it 'returns all terminal nodes' do
      expect(dag.terminals).to eq([:d])
    end

    it 'returns all source nodes' do
      expect(dag.sources).to eq([:a])
    end
  end

  describe '#topological_sort' do
    it 'sorts nodes in dependency order' do
      dag.add_edge(:a, :b)
      dag.add_edge(:b, :c)
      dag.add_edge(:a, :c)

      result = dag.topological_sort
      expect(result.index(:a)).to be < result.index(:b)
      expect(result.index(:b)).to be < result.index(:c)
    end

    it 'handles diamond pattern' do
      dag.add_edge(:a, :b)
      dag.add_edge(:a, :c)
      dag.add_edge(:b, :d)
      dag.add_edge(:c, :d)

      result = dag.topological_sort
      expect(result.index(:a)).to be < result.index(:b)
      expect(result.index(:a)).to be < result.index(:c)
      expect(result.index(:b)).to be < result.index(:d)
      expect(result.index(:c)).to be < result.index(:d)
    end
  end

  describe '#validate!' do
    it 'passes for valid DAG' do
      dag.add_edge(:a, :b)
      dag.add_edge(:b, :c)

      expect { dag.validate! }.not_to raise_error
    end

    it 'raises error for non-existent target' do
      # Manually create invalid state (can't happen through normal API)
      dag.add_node(:a)
      dag.instance_variable_get(:@edges)[:a] << :nonexistent

      expect { dag.validate! }.to raise_error(Minigun::Error, /nonexistent/)
    end

    it 'detects cycles' do
      dag.add_edge(:a, :b)
      dag.add_edge(:b, :c)

      # Adding c->a creates a cycle and should raise immediately
      expect { dag.add_edge(:c, :a) }.to raise_error(Minigun::Error, /Circular dependency/)
    end
  end

  describe '#build_sequential!' do
    it 'connects nodes in order' do
      dag.add_node(:a)
      dag.add_node(:b)
      dag.add_node(:c)

      dag.build_sequential!

      expect(dag.downstream(:a)).to eq([:b])
      expect(dag.downstream(:b)).to eq([:c])
      expect(dag.downstream(:c)).to be_empty
    end
  end

  describe '#fill_sequential_gaps!' do
    it 'fills in missing connections' do
      dag.add_node(:a)
      dag.add_node(:b)
      dag.add_node(:c)
      dag.add_edge(:a, :c)  # Skip b

      dag.fill_sequential_gaps!

      expect(dag.downstream(:b)).to eq([:c])
    end

    it 'does not override existing connections' do
      dag.add_node(:a)
      dag.add_node(:b)
      dag.add_node(:c)
      dag.add_edge(:a, :c)

      dag.fill_sequential_gaps!

      expect(dag.downstream(:a)).to eq([:c])
    end
  end

  describe '#execution_groups' do
    it 'groups stages that can run in parallel' do
      dag.add_edge(:a, :b)
      dag.add_edge(:a, :c)
      dag.add_edge(:b, :d)
      dag.add_edge(:c, :d)

      groups = dag.execution_groups

      expect(groups[0]).to eq([:a])
      expect(groups[1]).to contain_exactly(:b, :c)
      expect(groups[2]).to eq([:d])
    end
  end

  describe '#to_s' do
    it 'provides readable debug output' do
      dag.add_edge(:a, :b)
      dag.add_edge(:b, :c)

      output = dag.to_s

      expect(output).to include('DAG with')
      expect(output).to include('a →')
      expect(output).to include('b →')
    end
  end
end

