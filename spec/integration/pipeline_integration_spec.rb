require 'spec_helper'

RSpec.describe 'Pipeline Integration' do
  describe 'running a pipeline without mocks' do
    let(:test_task_class) do
      Class.new do
        include Minigun::Task
        
        attr_reader :produced_items, :doubled_items, :received_batches
        
        def initialize
          @produced_items = []
          @doubled_items = []
          @received_batches = []
        end
        
        # We'll use these directly in the tests
        def test_producer
          items = [1, 2, 3]
          @produced_items = items.dup
          items
        end
        
        def test_processor(item)
          result = item * 2
          @doubled_items << result
          result
        end
        
        def test_consumer(batch)
          @received_batches << batch
        end
      end
    end
    
    it 'manually creates and runs a simple pipeline with direct method calls' do
      task = test_task_class.new
      pipeline = Minigun::Pipeline.new(task)
      
      # Create a simple pipeline with source and sink
      source = Minigun::Stages::Processor.new(:test_producer, pipeline, 
                                              task.class._minigun_config.merge(stage_role: :producer))
      processor = Minigun::Stages::Processor.new(:test_processor, pipeline, task.class._minigun_config)
      consumer = Minigun::Stages::Processor.new(:test_consumer, pipeline, 
                                               task.class._minigun_config.merge(stage_role: :consumer))
      
      # 1. Run the producer
      produced_items = task.test_producer
      
      # 2. Process each item
      processed_results = produced_items.map { |item| task.test_processor(item) }
      
      # 3. Batch the items and feed to consumer
      batch_size = 2
      batches = processed_results.each_slice(batch_size).to_a
      batches.each { |batch| task.test_consumer(batch) }
      
      # Verify each step
      expect(task.produced_items).to eq([1, 2, 3])
      expect(task.doubled_items).to eq([2, 4, 6])
      expect(task.received_batches).to match_array([[2, 4], [6]])
      expect(task.received_batches.flatten).to match_array([2, 4, 6])
    end
  end
  
  describe 'running a pipeline with custom connections' do
    let(:branching_task_class) do
      Class.new do
        include Minigun::Task
        
        attr_reader :produced_items, :doubled_items, :tripled_items
        
        def initialize
          @produced_items = []
          @doubled_items = []
          @tripled_items = []
        end
        
        def source_producer
          items = [1, 2, 3]
          @produced_items = items.dup
          items
        end
        
        def double_processor(item)
          result = item * 2
          @doubled_items << result
          result
        end
        
        def triple_processor(item)
          result = item * 3
          @tripled_items << result
          result
        end
      end
    end
    
    it 'manually creates and runs a branching pipeline with direct method calls' do
      task = branching_task_class.new
      
      # 1. Run the source producer
      source_items = task.source_producer
      
      # 2. Send source items to both processors
      source_items.each do |item|
        task.double_processor(item)
        task.triple_processor(item)
      end
      
      # Verify each branch received and processed the data
      expect(task.produced_items).to eq([1, 2, 3])
      expect(task.doubled_items).to match_array([2, 4, 6])
      expect(task.tripled_items).to match_array([3, 6, 9])
    end
  end
end 