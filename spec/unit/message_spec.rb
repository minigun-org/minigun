# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Minigun::Message do
  describe '#initialize' do
    it 'creates a message with type and source' do
      message = described_class.new(type: :end, source: :producer_stage)

      expect(message.type).to eq(:end)
      expect(message.source).to eq(:producer_stage)
    end

    it 'accepts custom message types' do
      message = described_class.new(type: :custom_signal, source: :some_stage)

      expect(message.type).to eq(:custom_signal)
      expect(message.source).to eq(:some_stage)
    end
  end

  describe '#end_of_stream?' do
    it 'returns true for end-type messages' do
      message = described_class.new(type: :end, source: :stage_a)

      expect(message.end_of_stream?).to be true
    end

    it 'returns false for non-end messages' do
      message = described_class.new(type: :start, source: :stage_b)

      expect(message.end_of_stream?).to be false
    end

    it 'returns false for custom message types' do
      message = described_class.new(type: :custom, source: :stage_c)

      expect(message.end_of_stream?).to be false
    end
  end

  describe '.end_signal' do
    it 'creates an end-type message' do
      message = described_class.end_signal(source: :producer)

      expect(message).to be_a(Minigun::Message)
      expect(message.type).to eq(:end)
      expect(message.source).to eq(:producer)
    end

    it 'creates end_of_stream messages' do
      message = described_class.end_signal(source: :transform_stage)

      expect(message.end_of_stream?).to be true
    end
  end

  describe 'immutability' do
    it 'provides read-only access to type' do
      message = described_class.new(type: :end, source: :stage)

      expect { message.type = :different }.to raise_error(NoMethodError)
    end

    it 'provides read-only access to source' do
      message = described_class.new(type: :end, source: :stage)

      expect { message.source = :different }.to raise_error(NoMethodError)
    end
  end

  describe 'equality and comparison' do
    it 'creates distinct instances' do
      msg1 = described_class.end_signal(source: :stage_a)
      msg2 = described_class.end_signal(source: :stage_a)

      expect(msg1).not_to be(msg2)
    end

    it 'has same attributes for same parameters' do
      msg1 = described_class.end_signal(source: :stage_a)
      msg2 = described_class.end_signal(source: :stage_a)

      expect(msg1.type).to eq(msg2.type)
      expect(msg1.source).to eq(msg2.source)
    end
  end
end

