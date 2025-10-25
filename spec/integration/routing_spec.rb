# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Stage Routing with to:' do
  before do
    allow(Minigun.logger).to receive(:info)
  end

  describe 'Sequential routing (default)' do
    let(:pipeline_class) do
      Class.new do
        include Minigun::DSL

        attr_accessor :results

        def initialize
          @results = []
        end

        pipeline do
          producer :generate do
            3.times { |i| emit(i + 1) }
          end

          processor :double do |num|
            emit(num * 2)
          end

          processor :add_ten do |num|
            emit(num + 10)
          end

          consumer :collect do |num|
            results << num
          end
        end
      end
    end

    it 'processes items sequentially through all stages' do
      pipeline = pipeline_class.new
      pipeline.run

      expect(pipeline.results).to contain_exactly(12, 14, 16)
    end
  end

  describe 'Diamond pattern routing' do
    let(:pipeline_class) do
      Class.new do
        include Minigun::DSL

        attr_accessor :results_a, :results_b, :merged

        def initialize
          @results_a = []
          @results_b = []
          @merged = []
          @mutex = Mutex.new
        end

        pipeline do
          producer :source, to: [:path_a, :path_b] do
            3.times { |i| emit(i + 1) }
          end

          processor :path_a, to: :merge do |num|
            result = num * 2
            @mutex.synchronize { results_a << result }
            emit(result)
          end

          processor :path_b, to: :merge do |num|
            result = num * 3
            @mutex.synchronize { results_b << result }
            emit(result)
          end

          consumer :merge do |num|
            @mutex.synchronize { merged << num }
          end
        end
      end
    end

    it 'splits to multiple processors and merges results' do
      pipeline = pipeline_class.new
      pipeline.run

      expect(pipeline.results_a.sort).to eq([2, 4, 6])
      expect(pipeline.results_b.sort).to eq([3, 6, 9])
      expect(pipeline.merged.size).to eq(6) # 3 from each path
      expect(pipeline.merged.sort).to eq([2, 3, 4, 6, 6, 9])
    end
  end

  describe 'Fan-out pattern routing' do
    let(:pipeline_class) do
      Class.new do
        include Minigun::DSL

        attr_accessor :emails, :sms, :push

        def initialize
          @emails = []
          @sms = []
          @push = []
          @mutex = Mutex.new
        end

        pipeline do
          producer :generate, to: [:email_sender, :sms_sender, :push_sender] do
            3.times { |i| emit(i + 1) }
          end

          consumer :email_sender do |num|
            @mutex.synchronize { emails << num }
          end

          consumer :sms_sender do |num|
            @mutex.synchronize { sms << num }
          end

          consumer :push_sender do |num|
            @mutex.synchronize { push << num }
          end
        end
      end
    end

    it 'sends items to all specified consumers' do
      pipeline = pipeline_class.new
      pipeline.run

      expect(pipeline.emails.sort).to eq([1, 2, 3])
      expect(pipeline.sms.sort).to eq([1, 2, 3])
      expect(pipeline.push.sort).to eq([1, 2, 3])
    end
  end

  describe 'Complex routing with multiple splits' do
    let(:pipeline_class) do
      Class.new do
        include Minigun::DSL

        attr_accessor :validated, :archived, :stored, :logged

        def initialize
          @validated = []
          @archived = []
          @stored = []
          @logged = []
          @mutex = Mutex.new
        end

        pipeline do
          producer :fetch, to: [:validate, :log] do
            5.times { |i| emit(i + 1) }
          end

          processor :validate, to: [:archive, :store] do |num|
            @mutex.synchronize { validated << num }
            emit(num) if num.even?
          end

          consumer :store do |num|
            @mutex.synchronize { stored << num }
          end

          consumer :archive do |num|
            @mutex.synchronize { archived << num }
          end

          consumer :log do |num|
            @mutex.synchronize { logged << num }
          end
        end
      end
    end

    it 'routes items through complex paths' do
      pipeline = pipeline_class.new
      pipeline.run

      expect(pipeline.logged.sort).to eq([1, 2, 3, 4, 5])
      expect(pipeline.validated.sort).to eq([1, 2, 3, 4, 5])
      expect(pipeline.archived.sort).to eq([2, 4]) # Only evens
      expect(pipeline.stored.sort).to eq([2, 4])   # Only evens
    end
  end

  describe 'Single target with to:' do
    let(:pipeline_class) do
      Class.new do
        include Minigun::DSL

        attr_accessor :results

        def initialize
          @results = []
        end

        pipeline do
          producer :generate, to: :process do
            3.times { |i| emit(i) }
          end

          consumer :process do |num|
            results << num
          end
        end
      end
    end

    it 'works with single target (not array)' do
      pipeline = pipeline_class.new
      pipeline.run

      expect(pipeline.results.sort).to eq([0, 1, 2])
    end
  end

  describe 'Mixed routing - some with to:, some sequential' do
    let(:pipeline_class) do
      Class.new do
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

          # Path A is explicit
          processor :path_a, to: :collect do |num|
            @mutex.synchronize { from_a << num }
            emit(num * 10)
          end

          # Path B connects sequentially to transform, then to collect
          processor :path_b do |num|
            @mutex.synchronize { from_b << num }
            emit(num * 100)
          end

          processor :transform, to: :collect do |num|
            emit(num + 1)
          end

          consumer :collect do |num|
            @mutex.synchronize { final << num }
          end
        end
      end
    end

    it 'handles mixed explicit and sequential routing' do
      pipeline = pipeline_class.new
      pipeline.run

      expect(pipeline.from_a.sort).to eq([0, 1, 2])
      expect(pipeline.from_b.sort).to eq([0, 1, 2])
      # Path A: 0*10=0, 1*10=10, 2*10=20
      # Path B: (0*100)+1=1, (1*100)+1=101, (2*100)+1=201
      expect(pipeline.final.sort).to eq([0, 1, 10, 20, 101, 201])
    end
  end

  describe 'Error: stage references non-existent target' do
    let(:pipeline_class) do
      Class.new do
        include Minigun::DSL

        pipeline do
          producer :generate, to: :nonexistent do
            emit(1)
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

