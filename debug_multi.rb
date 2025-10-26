require_relative "lib/minigun"

class Test
  include Minigun::DSL
  attr_accessor :results

  def initialize
    @results = []
  end

  pipeline :gen, to: :proc do
    producer :p do
      puts "GEN producer"
      emit(1)
    end
    consumer :c do |x|
      puts "GEN consumer: #{x}, emitting..."
      emit(x)
    end
  end

  pipeline :proc do
    consumer :c do |x|
      puts "PROC consumer: #{x}, storing..."
      results << x
    end
  end
end

t = Test.new
t.run

puts "Results: #{t.results.inspect}"

