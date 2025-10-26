require 'minigun'
require 'rspec'

RSpec.describe "Test with stubbed logger" do
  before do
    allow(Minigun.logger).to receive(:info)
  end

  it "loads and runs example" do
    load File.expand_path('examples/13_configuration.rb', __dir__)

    example = ConfigurationExample.new
    example.run

    puts "\nResults size: #{example.results.size}"

    expect(example.results.size).to eq(18)
  end
end

