require_relative "lib/minigun"
require_relative "spec/spec_helper"

RSpec.describe "standalone emit test" do
  it 'works' do
    klass = Class.new do
      include Minigun::DSL
      attr_accessor :results

      def initialize
        @results = []
      end

      pipeline do
        producer :gen do
          emit({ id: 1, route: :fast })
          emit({ id: 2, route: :slow })
          emit({ id: 3, route: :fast })
        end

        stage :router do |item|
          emit_to_stage(item[:route], item)
        end

        consumer :fast do |item|
          puts "[FAST] Processing item #{item[:id]}, @results object_id: #{@results.object_id}"
          @results << { stage: :fast, id: item[:id] }
          puts "[FAST] After push, size: #{@results.size}"
        end

        consumer :slow do |item|
          puts "[SLOW] Processing item #{item[:id]}, @results object_id: #{@results.object_id}"
          @results << { stage: :slow, id: item[:id] }
          puts "[SLOW] After push, size: #{@results.size}"
        end
      end
    end

    pipeline = klass.new
    puts "Before run, results size: #{pipeline.results.size}"

    begin
      pipeline.run
      puts "After run completed"
    rescue => e
      puts "Exception during run: #{e.message}"
      puts e.backtrace.join("\n")
    end

    # Debug output
    puts "Results size: #{pipeline.results.size}"
    puts "Results: #{pipeline.results.inspect}"
    puts "Results object_id: #{pipeline.results.object_id}"

    expect(pipeline.results.size).to eq(3)
  end
end

