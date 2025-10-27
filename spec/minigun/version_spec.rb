# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Minigun do
  it 'has a version number' do
    expect(Minigun::VERSION).not_to be_nil
    expect(Minigun::VERSION).to match(/^\d+\.\d+\.\d+$/)
  end
end
