require_relative "lib/minigun"

klass = Class.new do
  include Minigun::DSL

  pipeline do
    producer :gen do
      emit({ id: 1 })
    end

    stage :router do |item|
      emit_to_stage(:fast, item)
      emit_to_stage(:slow, item)
    end

    consumer :fast do |item|
      # no-op
    end

    consumer :slow do |item|
      # no-op
    end
  end
end

task = klass.new

puts "Stages:"
task.stages.each_key { |name| puts "  - #{name}" }

puts "\nDAG Edges:"
task.stages.each_key do |from|
  downstream = task.dag.downstream(from)
  downstream.each do |to|
    puts "  #{from} -> #{to}"
  end
end

