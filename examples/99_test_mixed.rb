#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

class TestMixedExample
  include Minigun::DSL

  attr_accessor :from_a, :from_b, :final

  def initialize
    @from_a = []
    @from_b = []
    @final = []
    @mutex = Mutex.new
  end

  pipeline do
    producer :generate, to: [:path_a, :path_b] do
      3.times { |i| emit(i) }
    end

    processor :path_a, to: :collect do |num|
      result = num * 10
      @mutex.synchronize { from_a << num }
      emit(result)
    end

    processor :path_b do |num|
      result = num * 100
      @mutex.synchronize { from_b << num }
      emit(result)
    end

    processor :transform, to: :collect do |num|
      result = num + 1
      emit(result)
    end

    consumer :collect do |num|
      @mutex.synchronize { final << num }
    end
  end
end

if __FILE__ == $0
  example = TestMixedExample.new
  example.run
  puts "final: #{example.final.sort.inspect}"
  puts "expected: [0, 1, 10, 20, 101, 201]"
  puts example.final.sort == [0, 1, 10, 20, 101, 201] ? "✓ Pass" : "✗ Fail"
end

