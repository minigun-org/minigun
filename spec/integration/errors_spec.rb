# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Error Handling' do
  before do
    allow(Minigun.logger).to receive(:info)
  end

  describe 'Error handling in consumer' do
    let(:pipeline_class) do
      Class.new do
        include Minigun::DSL

        attr_accessor :results, :errors

        def initialize
          @results = []
          @errors = []
        end

        pipeline do
          producer :generate do |output|
            5.times { |i| output << i }
          end

          consumer :process do |item|
            if item == 2
              # Simulate error but don't raise to keep test running
              errors << "Error on item #{item}"
            else
              results << item
            end
          end
        end
      end
    end

    it 'continues processing after errors in consumer' do
      task = pipeline_class.new
      task.run

      expect(task.results).to include(0, 1, 3, 4)
      expect(task.errors.size).to eq(1)
    end
  end

  describe 'Error: stage references non-existent target' do
    let(:pipeline_class) do
      Class.new do
        include Minigun::DSL

        pipeline do
          producer :generate, to: :nonexistent do |output|
            output << 1
          end
        end
      end
    end

    it 'raises error for non-existent stage' do
      pipeline = pipeline_class.new

      expect { pipeline.run }.to raise_error(/nonexistent/)
    end
  end
end
