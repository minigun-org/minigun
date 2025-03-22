require 'rspec'

RSpec.describe "Simple Test" do
  it "passes" do
    expect(true).to eq(true)
  end
  
  it "also passes" do
    expect(1 + 1).to eq(2)
  end
end 