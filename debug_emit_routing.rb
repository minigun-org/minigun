require_relative "lib/minigun"

results = []

klass = Class.new do
  include Minigun::DSL

  define_method(:initialize) do
    @results = results
  end

  pipeline do
    producer :gen do
      puts "[GEN] Emitting 3 items"
      emit({ id: 1, route: :fast })
      emit({ id: 2, route: :slow })
      emit({ id: 3, route: :fast })
    end

    stage :router do |item|
      puts "[ROUTER] Routing item #{item[:id]} to #{item[:route]}"
      emit_to_stage(item[:route], item)
    end

    consumer :fast do |item|
      puts "[FAST] Received item #{item[:id]}"
      @results << { stage: :fast, id: item[:id] }
    end

    consumer :slow do |item|
      puts "[SLOW] Received item #{item[:id]}"
      @results << { stage: :slow, id: item[:id] }
    end
  end
end

pipeline = klass.new
pipeline.run

puts "\nResults: #{results.inspect}"
puts "Expected 3, got #{results.size}"

