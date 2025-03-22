# frozen_string_literal: true

require 'rspec'

RSpec.describe 'Simple Test' do
  it 'passes' do
    expect(true).to be(true)
  end

  it 'also passes' do
    expect(1 + 1).to eq(2)
  end
end
