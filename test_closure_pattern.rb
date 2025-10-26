require_relative "lib/minigun"
require_relative "spec/spec_helper"

RSpec.describe "closure pattern" do
  it 'works with closure' do
    results = []

    klass = Class.new do
      include Minigun::DSL

      define_method(:initialize) do
        puts "[INIT] Closure results object_id: #{results.object_id}"
        @results = results
        puts "[INIT] @results object_id: #{@results.object_id}"
      end

      pipeline do
        producer :gen do
          puts "[GEN] producing"
          emit(1)
          emit(2)
          emit(3)
        end

        consumer :consume do |item|
          puts "[CONSUME] item=#{item}, @results.object_id=#{@results.object_id}"
          @results << item
          puts "[CONSUME] @results.size=#{@results.size}"
        end
      end
    end

    pipeline = klass.new
    puts "\n[BEFORE RUN] results.object_id=#{results.object_id}, size=#{results.size}"
    pipeline.run
    puts "\n[AFTER RUN] results.object_id=#{results.object_id}, size=#{results.size}"
    puts "Results: #{results.inspect}"

    expect(results.size).to eq(3)
  end
end

