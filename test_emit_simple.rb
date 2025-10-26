require_relative "lib/minigun"
require_relative "spec/spec_helper"

RSpec.describe "emit_to_stage simple" do
  it 'routes items' do
    results = []

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
          @results << { stage: :fast, id: item[:id] }
        end

        consumer :slow do |item|
          @results << { stage: :slow, id: item[:id] }
        end
      end
    end

    pipeline = klass.new
    pipeline.run

    puts "Results: #{pipeline.results.inspect}"
    expect(pipeline.results.size).to eq(3)
  end
end

