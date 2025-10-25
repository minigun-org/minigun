# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Simple Test' do # rubocop:disable RSpec/DescribeClass
  it 'passes' do
    expect(1 + 1).to eq(2)
  end
end
