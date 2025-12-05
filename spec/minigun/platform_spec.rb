# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Minigun::Platform do
  # Clear memoized values before each test
  before do
    %i[@linux @macos @windows @mri @jruby @truffleruby @fork @fibers @ractors].each do |var|
      described_class.remove_instance_variable(var) if described_class.instance_variable_defined?(var)
    end
  end

  describe '.fork?' do
    it 'returns a boolean' do
      expect([true, false]).to include(described_class.fork?) # rubocop:disable RSpec/ExpectActual
    end

    it 'memoizes the result' do
      first_call = described_class.fork?
      second_call = described_class.fork?

      expect(first_call).to eq(second_call)
      expect(described_class.instance_variable_defined?(:@fork)).to be true
    end

    it 'returns false when Process does not respond to fork' do
      allow(Process).to receive(:respond_to?).with(:fork).and_return(false)

      expect(described_class.fork?).to be false
    end

    it 'returns false on TruffleRuby even if Process.fork exists' do
      allow(Process).to receive(:respond_to?).with(:fork).and_return(true)
      allow(described_class).to receive(:truffleruby?).and_return(true)

      expect(described_class.fork?).to be false
    end

    it 'returns true when Process.fork exists and not TruffleRuby' do
      allow(Process).to receive(:respond_to?).with(:fork).and_return(true)
      allow(described_class).to receive(:truffleruby?).and_return(false)

      expect(described_class.fork?).to be true
    end
  end

  describe '.windows?' do
    it 'returns a boolean' do
      expect([true, false]).to include(described_class.windows?) # rubocop:disable RSpec/ExpectActual
    end

    it 'memoizes the result' do
      first_call = described_class.windows?
      second_call = described_class.windows?

      expect(first_call).to eq(second_call)
      expect(described_class.instance_variable_defined?(:@windows)).to be true
    end

    it 'delegates to Gem.win_platform?' do
      allow(Gem).to receive(:win_platform?).and_return(true)

      expect(described_class.windows?).to be true
    end
  end

  describe '.jruby?' do
    it 'returns a boolean' do
      expect([true, false]).to include(described_class.jruby?) # rubocop:disable RSpec/ExpectActual
    end

    it 'memoizes the result' do
      first_call = described_class.jruby?
      second_call = described_class.jruby?

      expect(first_call).to eq(second_call)
      expect(described_class.instance_variable_defined?(:@jruby)).to be true
    end

    it 'returns true when RUBY_ENGINE is jruby' do
      stub_const('RUBY_ENGINE', 'jruby')

      expect(described_class.jruby?).to be true
    end

    it 'returns false when RUBY_ENGINE is not jruby' do
      stub_const('RUBY_ENGINE', 'ruby')

      expect(described_class.jruby?).to be false
    end
  end

  describe '.truffleruby?' do
    it 'returns a boolean' do
      expect([true, false]).to include(described_class.truffleruby?) # rubocop:disable RSpec/ExpectActual
    end

    it 'memoizes the result' do
      first_call = described_class.truffleruby?
      second_call = described_class.truffleruby?

      expect(first_call).to eq(second_call)
      expect(described_class.instance_variable_defined?(:@truffleruby)).to be true
    end

    it 'returns true when RUBY_ENGINE is truffleruby' do
      stub_const('RUBY_ENGINE', 'truffleruby')

      expect(described_class.truffleruby?).to be true
    end

    it 'returns false when RUBY_ENGINE is not truffleruby' do
      stub_const('RUBY_ENGINE', 'ruby')

      expect(described_class.truffleruby?).to be false
    end
  end

  describe 'module extension' do
    it 'extends self for direct method calls' do
      expect(described_class).to respond_to(:fork?)
      expect(described_class).to respond_to(:windows?)
      expect(described_class).to respond_to(:jruby?)
      expect(described_class).to respond_to(:truffleruby?)
    end
  end
end
