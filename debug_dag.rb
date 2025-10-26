require_relative "lib/minigun"

class Test
  include Minigun::DSL
  pipeline do
    producer :gen do
      emit(1)
    end
    processor :proc do |x|
      puts "PROC: #{x}"
      emit(x * 2)
    end
    consumer :cons do |x|
      puts "CONS: #{x}"
    end
  end
end

t = Test.new

# Trigger pipeline build by calling run
Thread.new do
  t.run
end

sleep 0.1  # Let it build

p = t.class._minigun_task.root_pipeline
puts "DAG edges:"
edges = p.dag.instance_variable_get(:@edges) || {}
edges.each { |from, tos| puts "  #{from} -> #{tos.inspect}" }

puts "\nStages:"
stages = p.instance_variable_get(:@stages) || {}
stages.keys.each { |stage| puts "  #{stage.inspect}" }

