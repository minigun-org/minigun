require 'minigun'
require 'rspec'

RSpec.describe "Minimal test" do
  it "loads and runs example" do
    load File.expand_path('examples/13_configuration.rb', __dir__)

    example = ConfigurationExample.new
    example.run

    puts "\nResults size: #{example.results.size}"
    puts "Results: #{example.results.sort.inspect}"

    expect(example.results.size).to eq(18)
  end
end

