# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Test Mixed Routing' do
  it 'works correctly' do
    load File.expand_path('../../examples/99_test_mixed.rb', __dir__)

    example = TestMixedExample.new
    example.run

    expect(example.from_a.sort).to eq([0, 1, 2])
    expect(example.from_b.sort).to eq([0, 1, 2])
    expect(example.final.sort).to eq([0, 1, 10, 20, 101, 201])
  end
end
