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
    producer :generate, to: [:path_a, :path_b] do |output|
      3.times { |i| output << i }
    end

    processor :path_a, to: :collect do |num, output|
      result = num * 10
      @mutex.synchronize { from_a << num }
      output << result
    end

    processor :path_b do |num, output|
      result = num * 100
      @mutex.synchronize { from_b << num }
      output << result
    end

    processor :transform, to: :collect do |num, output|
      result = num + 1
      output << result
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

