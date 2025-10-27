# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Debug 16_mixed_routing' do
  it 'shows DAG structure' do
    load File.expand_path('../../examples/16_mixed_routing.rb', __dir__)

    example = MixedRoutingExample.new

    # Access the task and pipeline
    task = example.class._minigun_task
    pipeline = task.root_pipeline

    puts "\n=== BEFORE RUN ==="
    puts "Stages: #{pipeline.stages.keys.inspect}"

    example.run

    puts "\n=== AFTER RUN ==="
    puts 'DAG edges:'
    pipeline.dag.edges.each do |from, targets|
      puts "  #{from} -> #{targets.to_a.join(', ')}"
    end

    puts "\nResults:"
    puts "  from_a: #{example.from_a.sort.inspect}"
    puts "  from_b: #{example.from_b.sort.inspect}"
    puts "  final: #{example.final.sort.inspect}"
    puts '  expected final: [0, 1, 10, 20, 101, 201]'
  end
end
