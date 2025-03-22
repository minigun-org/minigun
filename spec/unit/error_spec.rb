require 'spec_helper'

RSpec.describe Minigun::Error do
  it 'is a subclass of StandardError' do
    expect(described_class).to be < StandardError
  end

  it 'can be raised with a message' do
    error_message = 'This is a test error'
    expect { raise Minigun::Error, error_message }.to raise_error(Minigun::Error, error_message)
  end
end 