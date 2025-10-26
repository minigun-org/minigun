require_relative "lib/minigun"

class SimpleTest
  include Minigun::DSL

  attr_accessor :results

  def initialize
    @results = []
  end

  pipeline do
    producer :generate do
      puts "Generating 3 items"
      3.times { |i| emit(i) }
    end

    consumer :collect do |item|
      puts "Collecting: #{item}"
      @results << item
    end
  end
end

test = SimpleTest.new
test.run
puts "Results: #{test.results.inspect}"
puts "Expected: [0, 1, 2]"
puts test.results.size == 3 ? "PASS" : "FAIL - got #{test.results.size} items"

