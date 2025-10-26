require_relative "lib/minigun"

results = []

klass = Class.new do
  include Minigun::DSL
  attr_accessor :results

  def initialize
    @results = []
    puts "[INIT] initialized with @results = #{@results.object_id}"
  end

  pipeline do
    producer :gen do
      puts "[GEN] producing"
      emit({ id: 1, route: :fast })
      emit({ id: 2, route: :slow })
      emit({ id: 3, route: :fast })
      puts "[GEN] done producing"
    end

    stage :router do |item|
      puts "[ROUTER] routing #{item.inspect}"
      emit_to_stage(item[:route], item)
    end

    consumer :fast do |item|
      puts "[FAST] consuming #{item.inspect}, @results = #{@results.object_id}"
      @results << { stage: :fast, id: item[:id] }
      puts "[FAST] @results now has #{@results.size} items"
    end

    consumer :slow do |item|
      puts "[SLOW] consuming #{item.inspect}, @results = #{@results.object_id}"
      @results << { stage: :slow, id: item[:id] }
      puts "[SLOW] @results now has #{@results.size} items"
    end
  end
end

pipeline = klass.new
puts "\n[BEFORE RUN] @results = #{pipeline.results.object_id}, size = #{pipeline.results.size}"
pipeline.run
puts "\n[AFTER RUN] @results = #{pipeline.results.object_id}, size = #{pipeline.results.size}"
puts "Results: #{pipeline.results.inspect}"

