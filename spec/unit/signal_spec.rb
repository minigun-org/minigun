# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Minigun::EndOfSource do
  describe '#initialize' do
    it 'creates a signal with source' do
      signal = described_class.new(source: :producer_stage)

      expect(signal.source).to eq(:producer_stage)
    end
  end

  describe '.from' do
    it 'creates an EndOfSource signal' do
      signal = described_class.from(source: :producer)

      expect(signal).to be_a(described_class)
      expect(signal.source).to eq(:producer)
    end
  end

  describe '#to_s and #inspect' do
    it 'provides readable string representation' do
      signal = described_class.new(source: :stage_a)

      expect(signal.to_s).to eq('EndOfSource(stage_a)')
      expect(signal.inspect).to eq('EndOfSource(stage_a)')
    end
  end

  describe 'inheritance' do
    it 'inherits from QueueSignal' do
      signal = described_class.new(source: :stage)

      expect(signal).to be_a(Minigun::QueueSignal)
    end
  end

  describe 'immutability' do
    it 'provides read-only access to source' do
      signal = described_class.new(source: :stage)

      expect { signal.source = :different }.to raise_error(NoMethodError)
    end
  end

  describe 'equality and comparison' do
    it 'creates distinct instances' do
      sig1 = described_class.from(source: :stage_a)
      sig2 = described_class.from(source: :stage_a)

      expect(sig1).not_to be(sig2)
    end

    it 'has same attributes for same parameters' do
      sig1 = described_class.from(source: :stage_a)
      sig2 = described_class.from(source: :stage_a)

      expect(sig1.source).to eq(sig2.source)
    end
  end
end

RSpec.describe Minigun::EndOfStage do
  describe '#initialize' do
    it 'creates a signal with stage_name' do
      signal = described_class.new(:test_stage)

      expect(signal.stage_name).to eq(:test_stage)
    end
  end

  describe '.instance' do
    it 'returns singleton per stage' do
      sig1 = described_class.instance(:stage_a)
      sig2 = described_class.instance(:stage_a)

      expect(sig1).to be(sig2) # Same object
    end

    it 'returns different singletons for different stages' do
      sig_a = described_class.instance(:stage_a)
      sig_b = described_class.instance(:stage_b)

      expect(sig_a).not_to be(sig_b)
      expect(sig_a.stage_name).to eq(:stage_a)
      expect(sig_b.stage_name).to eq(:stage_b)
    end
  end

  describe '#to_s and #inspect' do
    it 'provides readable string representation' do
      signal = described_class.instance(:my_stage)

      expect(signal.to_s).to eq('EndOfStage(my_stage)')
      expect(signal.inspect).to eq('EndOfStage(my_stage)')
    end
  end

  describe 'inheritance' do
    it 'inherits from QueueSignal' do
      signal = described_class.instance(:stage)

      expect(signal).to be_a(Minigun::QueueSignal)
    end
  end

  describe 'immutability' do
    it 'provides read-only access to stage_name' do
      signal = described_class.instance(:stage)

      expect { signal.stage_name = :different }.to raise_error(NoMethodError)
    end
  end
end

