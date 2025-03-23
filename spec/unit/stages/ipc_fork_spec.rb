# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Minigun::Stages::IpcFork do
  subject { described_class.new(stage_name, pipeline, config) }

  let(:consumer_block) { proc { |items| items.each { |i| processed << i } } }
  let(:task_class) do
    Class.new do
    end
  end

  let(:task) do
    task = double('Task')
    allow(task).to receive_messages(class: task_class, _minigun_hooks: {})
    allow(task).to receive(:instance_exec) do |item, &block|
      @processed ||= []
      attr_reader :processed

      block.call(item)
    end
    allow(task).to receive(:run_hooks)
    allow(task).to receive_messages(hooks: {}, stage_blocks: { test_consumer: consumer_block })
    task
  end

  let(:pipeline) { double('Pipeline', task: task, job_id: 'test_job', context: task) }
  let(:logger) { instance_double(Logger, info: nil, warn: nil, error: nil, debug: nil) }
  let(:config) do
    {
      logger: logger,
      max_threads: 2,
      max_retries: 2,
      fork_mode: :never # Force thread pool mode for predictable testing
    }
  end
  let(:stage_name) { :test_consumer }

  before do
    allow(pipeline).to receive(:downstream_stages).and_return([])
    # Reset mocks and stubs from previous examples
    RSpec::Mocks.space.proxy_for(subject).reset if RSpec::Mocks.space.proxy_for(subject)
  end

  describe '#initialize' do
    it 'sets up the consumer with the correct configuration' do
      expect(subject.instance_variable_get(:@stage_block)).to eq(consumer_block)
      expect(subject.instance_variable_get(:@max_threads)).to eq(2)
      expect(subject.instance_variable_get(:@max_retries)).to eq(2)
      expect(subject.instance_variable_get(:@fork_mode)).to eq(:never)
    end

    it 'creates a thread pool' do
      thread_pool = subject.instance_variable_get(:@thread_pool)
      expect(thread_pool).to be_a(Concurrent::FixedThreadPool)
      expect(thread_pool.max_length).to eq(2)
    end
    
    it 'sets default values for new configuration options' do
      expect(subject.instance_variable_get(:@pipe_timeout)).to eq(described_class::DEFAULT_PIPE_TIMEOUT)
      expect(subject.instance_variable_get(:@use_compression)).to eq(true)
    end
    
    it 'allows custom values for new configuration options' do
      config_with_options = config.merge(
        pipe_timeout: 60,
        use_compression: false
      )
      custom_subject = described_class.new(stage_name, pipeline, config_with_options)
      
      expect(custom_subject.instance_variable_get(:@pipe_timeout)).to eq(60)
      expect(custom_subject.instance_variable_get(:@use_compression)).to eq(false)
    end
  end

  describe '#process' do
    context 'with thread pool execution' do
      it 'processes items using the thread pool' do
        # Ensure fork is not used
        allow(Process).to receive(:respond_to?).with(:fork).and_return(false)

        # Reset counters to ensure accurate counting
        subject.instance_variable_set(:@processed_count, Concurrent::AtomicFixnum.new(0))

        # Setup fork context to track emits
        Thread.current[:minigun_fork_context] = {
          emit_count: 0,
          success_count: 3,
          failed_count: 0
        }

        # Create a simple thread pool that executes immediately for testing
        test_pool = double('ThreadPool')
        allow(test_pool).to receive(:post).and_yield
        subject.instance_variable_set(:@thread_pool, test_pool)

        # Stub process_items_directly
        allow(subject).to receive(:process_items_directly) do |items|
          # Increment the processed count
          subject.instance_variable_get(:@processed_count).increment(items.size)
          { success: items.size, failed: 0, emitted: 0 }
        end

        # Process some items
        subject.process([1, 2, 3])

        # Verify the items were processed
        expect(subject.instance_variable_get(:@processed_count).value).to eq(6)
      end
    end
    
    context 'with forking' do
      it 'calls GC.start before forking' do
        # Allow forking
        allow(Process).to receive(:respond_to?).with(:fork).and_return(true)
        
        # Mock fork to avoid actual process creation
        allow(Process).to receive(:fork).and_return(123)
        
        # Expect GC.start to be called
        expect(GC).to receive(:start)
        
        # Stub other methods to focus on the GC call
        allow_any_instance_of(IO).to receive(:binmode)
        allow_any_instance_of(IO).to receive(:close_on_exec=)
        allow_any_instance_of(IO).to receive(:close)
        
        # Process an item
        subject.process(1)
      end
    end
  end

  describe '#shutdown' do
    it 'shuts down the thread pool and returns processing statistics' do
      # Set up thread pool mock
      thread_pool = double('ThreadPool')
      allow(thread_pool).to receive(:shutdown)
      allow(thread_pool).to receive(:wait_for_termination).and_return(true)
      subject.instance_variable_set(:@thread_pool, thread_pool)

      # Set up statistics for testing
      processed_count = subject.instance_variable_get(:@processed_count)
      processed_count.increment(3)

      # Call shutdown
      result = subject.shutdown

      # Verify results
      expect(result[:processed]).to eq(3)
    end
  end
  
  describe '#process_batch' do
    it 'executes the stage block with the provided batch' do
      # Create a test context and batch
      context = double('Context')
      batch = [1, 2, 3]
      
      # Set up the stage block as a proc
      stage_block = proc { |items| items.map { |i| i * 2 } }
      
      # Set up instance variables
      subject.instance_variable_set(:@context, context)
      subject.instance_variable_set(:@stage_block, stage_block)
      
      # Expect the block to be called with the batch
      expect(context).to receive(:instance_exec).with(batch, &stage_block)
      
      # Call process_batch
      subject.send(:process_batch, batch)
    end
  end
  
  describe '#process_items_in_child and #process_items_directly' do
    it 'uses batch processing with GC for large item sets' do
      # Create a larger batch to trigger batching
      items = (1..200).to_a
      
      # Setup for testing
      stage_block = proc { |batch| batch.map { |i| i * 2 } }
      context = double('Context')
      allow(context).to receive(:instance_exec).and_yield
      subject.instance_variable_set(:@context, context)
      subject.instance_variable_set(:@stage_block, stage_block)
      
      # Setup fork context
      Thread.current[:minigun_fork_context] = {
        emit_count: 0,
        success_count: 0,
        failed_count: 0
      }
      
      # Expect batch processing
      expect(subject).to receive(:process_batch).at_least(2).times
      
      # Setup random calls for GC probability
      allow(Random).to receive(:rand).and_return(0.05) # Below GC_PROBABILITY
      
      # Spy on GC.start
      allow(GC).to receive(:start).and_call_original
      
      # Call process_items_directly
      subject.send(:process_items_directly, items)
      
      # Verify GC.start was called
      expect(GC).to have_received(:start).at_least(1).times
    end
  end
  
  describe 'IPC serialization' do
    let(:test_data) { { complex: 'data', with: [1, 2, 3], and: { nested: true } } }
    let(:read_pipe) { instance_double(IO) }
    let(:write_pipe) { instance_double(IO) }
    
    before do
      allow(read_pipe).to receive(:binmode)
      allow(write_pipe).to receive(:binmode)
      allow(read_pipe).to receive(:close_on_exec=)
      allow(write_pipe).to receive(:close_on_exec=)
      allow(read_pipe).to receive(:close)
      allow(write_pipe).to receive(:close)
      allow(write_pipe).to receive(:write)
      allow(IO).to receive(:select).with([read_pipe], nil, nil, anything).and_return([[read_pipe]])
    end
    
    describe '#send_results_to_parent' do
      context 'when MessagePack is available' do
        before do
          # Skip test if MessagePack is not available in the environment
          skip "MessagePack not available for testing" unless MSGPACK_AVAILABLE_FOR_TESTS
          
          # Create a MessagePack-compatible object for testing
          allow(test_data).to receive(:to_msgpack).and_return("msgpack_data")

          # Mock defined? to return true for MessagePack
          allow(subject).to receive(:defined?).with(anything).and_call_original
          allow(subject).to receive(:defined?).with(MessagePack).and_return(true)
        end
        
        it 'uses MessagePack for serialization' do
          # Stub format byte write and data write
          expect(write_pipe).to receive(:write).with([1].pack('C')) # format byte for msgpack
          expect(write_pipe).to receive(:write).with([12].pack('L')) # length of "msgpack_data"
          expect(write_pipe).to receive(:write).with("msgpack_data")
          
          # Call the method
          subject.send(:send_results_to_parent, write_pipe, test_data)
        end
      end
      
      context 'when MessagePack is not available' do
        let(:marshal_data) { Marshal.dump(test_data) }
        
        before do
          # Mock defined? to consistently return false for MessagePack
          allow(subject).to receive(:defined?).with(anything).and_call_original
          allow(subject).to receive(:defined?).with(MessagePack).and_return(false)
        end
        
        it 'falls back to Marshal' do
          # Expect Marshal to be used
          expect(Marshal).to receive(:dump).with(test_data).and_return(marshal_data)
          
          # Stub format byte write and data write
          expect(write_pipe).to receive(:write).with([2].pack('C')) # format byte for marshal
          expect(write_pipe).to receive(:write).with([marshal_data.bytesize].pack('L'))
          expect(write_pipe).to receive(:write).with(marshal_data)
          
          # Call the method
          subject.send(:send_results_to_parent, write_pipe, test_data)
        end
      end
      
      context 'with compression enabled' do
        let(:large_data) { { data: "x" * 2000 } }
        let(:serialized) { Marshal.dump(large_data) }
        let(:compressed) { Zlib::Deflate.deflate(serialized) }
        
        before do
          # Ensure compression is beneficial
          expect(serialized.bytesize).to be > compressed.bytesize
          
          # Mock defined? to consistently return false for MessagePack
          allow(subject).to receive(:defined?).with(anything).and_call_original
          allow(subject).to receive(:defined?).with(MessagePack).and_return(false)
          
          # Set up Marshal to return serialized data
          allow(Marshal).to receive(:dump).with(large_data).and_return(serialized)
          
          # Set up Zlib to return compressed data
          allow(Zlib::Deflate).to receive(:deflate).with(serialized).and_return(compressed)
        end
        
        it 'compresses large data when beneficial' do
          # Stub format byte write and data write
          expect(write_pipe).to receive(:write).with([4].pack('C')) # format byte for marshal_compressed
          expect(write_pipe).to receive(:write).with([compressed.bytesize].pack('L'))
          expect(write_pipe).to receive(:write).with(compressed)
          
          # Call the method
          subject.send(:send_results_to_parent, write_pipe, large_data)
        end
      end
    end
    
    describe '#send_chunked_data' do
      it 'splits large data into chunks for transfer' do
        # Create data larger than a reasonable test chunk size (reduce MAX_CHUNK_SIZE for test)
        stub_const("Minigun::Stages::IpcFork::MAX_CHUNK_SIZE", 100)
        large_data = "x" * 210
        
        # Expected chunks
        chunks = [
          "x" * 100,
          "x" * 100,
          "x" * 10
        ]
        
        # Expect chunked header
        expect(write_pipe).to receive(:write).with([0xFFFFFFFF].pack('L'))
        expect(write_pipe).to receive(:write).with([large_data.bytesize, 3].pack('LL'))
        
        # Expect each chunk
        chunks.each do |chunk|
          expect(write_pipe).to receive(:write).with([chunk.bytesize].pack('L'))
          expect(write_pipe).to receive(:write).with(chunk)
        end
        
        # Call the method
        subject.send(:send_chunked_data, write_pipe, large_data)
      end
    end
    
    describe '#receive_results_from_child' do
      context 'with MessagePack format' do
        let(:format_byte) { 1 } # MessagePack format
        let(:test_result) { { result: 'msgpack success' } }
        let(:data_size) { 20 } # arbitrary size
        let(:msgpack_data) { "msgpack_serialized_data" }
        
        before do
          # Set up pipe to return format byte and data size
          allow(read_pipe).to receive(:read).with(1).and_return([format_byte].pack('C'))
          allow(read_pipe).to receive(:read).with(4).and_return([data_size].pack('L'))
          allow(read_pipe).to receive(:read).with(data_size).and_return(msgpack_data)
        end
        
        context 'when MessagePack is available' do
          before do
            skip "MessagePack not available for testing" unless MSGPACK_AVAILABLE_FOR_TESTS
            
            # Mock defined? to return true for MessagePack
            allow(subject).to receive(:defined?).with(anything).and_call_original
            allow(subject).to receive(:defined?).with(MessagePack).and_return(true)
          end
          
          it 'unpacks the data using MessagePack' do
            # Stub MessagePack.unpack
            expect(MessagePack).to receive(:unpack).with(msgpack_data).and_return(test_result)
            
            # Call the method
            result = subject.send(:receive_results_from_child, read_pipe)
            
            # Verify result
            expect(result).to eq(test_result)
          end
        end
        
        context 'when MessagePack is not available' do
          before do
            # Mock defined? to consistently return false for MessagePack
            allow(subject).to receive(:defined?).with(anything).and_call_original
            allow(subject).to receive(:defined?).with(MessagePack).and_return(false)
          end
          
          it 'falls back to Marshal.load' do
            # Set up Marshal to return test result
            allow(Marshal).to receive(:load).with(msgpack_data).and_return(test_result)
            
            # Call the method
            result = subject.send(:receive_results_from_child, read_pipe)
            
            # Verify result
            expect(result).to eq(test_result)
          end
        end
      end
      
      context 'with direct Marshal data' do
        let(:format_byte) { 2 } # Marshal format
        let(:test_result) { { result: 'success' } }
        let(:marshal_data) { Marshal.dump(test_result) }
        let(:data_size) { marshal_data.bytesize }
        
        before do
          # Set up pipe to return format byte and data size
          allow(read_pipe).to receive(:read).with(1).and_return([format_byte].pack('C'))
          allow(read_pipe).to receive(:read).with(4).and_return([data_size].pack('L'))
          allow(read_pipe).to receive(:read).with(data_size).and_return(marshal_data)
        end
        
        it 'reads and unmarshals the data' do
          # Call the method
          result = subject.send(:receive_results_from_child, read_pipe)
          
          # Verify result
          expect(result).to eq(test_result)
        end
      end
      
      context 'with chunked data' do
        let(:format_byte) { 2 } # Marshal format
        let(:data_size) { 0xFFFFFFFF } # Chunked data marker
        let(:test_result) { { result: 'chunked success' } }
        let(:marshalled_data) { Marshal.dump(test_result) }
        
        it 'reassembles chunked data' do
          # Setup for chunked data
          chunk1 = marshalled_data[0..50]
          chunk2 = marshalled_data[51..-1] || ""
          
          # Setup pipe reads
          allow(read_pipe).to receive(:read).with(1).and_return([format_byte].pack('C'))
          allow(read_pipe).to receive(:read).with(4).and_return([data_size].pack('L'))
          allow(read_pipe).to receive(:read).with(8).and_return([marshalled_data.bytesize, 2].pack('LL'))
          
          # Setup chunk reads in sequence
          allow(read_pipe).to receive(:read).with(4).and_return(
            [chunk1.bytesize].pack('L'),
            [chunk2.bytesize].pack('L')
          )
          allow(read_pipe).to receive(:read).with(chunk1.bytesize).and_return(chunk1)
          allow(read_pipe).to receive(:read).with(chunk2.bytesize).and_return(chunk2)
          
          # Call the method
          result = subject.send(:receive_results_from_child, read_pipe)
          
          # Verify result
          expect(result).to eq(test_result)
        end
      end
      
      context 'with compressed data' do
        let(:format_byte) { 4 } # Marshal compressed format
        let(:test_result) { { result: 'compressed success' } }
        let(:marshalled_data) { Marshal.dump(test_result) }
        let(:compressed_data) { Zlib::Deflate.deflate(marshalled_data) }
        let(:data_size) { compressed_data.bytesize }
        
        before do
          # Set up pipe to return format byte and data size
          allow(read_pipe).to receive(:read).with(1).and_return([format_byte].pack('C'))
          allow(read_pipe).to receive(:read).with(4).and_return([data_size].pack('L'))
          allow(read_pipe).to receive(:read).with(data_size).and_return(compressed_data)
        end
        
        it 'decompresses and unmarshals the data' do
          # Call the method
          result = subject.send(:receive_results_from_child, read_pipe)
          
          # Verify result
          expect(result).to eq(test_result)
        end
      end
      
      context 'with compressed MessagePack data' do
        let(:format_byte) { 3 } # MessagePack compressed format
        let(:test_result) { { result: 'msgpack compressed success' } }
        let(:data_size) { 20 } # arbitrary size
        let(:compressed_data) { "compressed_msgpack_data" }
        let(:decompressed_data) { "decompressed_msgpack_data" }
        
        before do
          # Set up pipe to return format byte and data size
          allow(read_pipe).to receive(:read).with(1).and_return([format_byte].pack('C'))
          allow(read_pipe).to receive(:read).with(4).and_return([data_size].pack('L'))
          allow(read_pipe).to receive(:read).with(data_size).and_return(compressed_data)
          
          # Setup decompression
          allow(Zlib::Inflate).to receive(:inflate).with(compressed_data).and_return(decompressed_data)
        end
        
        context 'when MessagePack is available' do
          before do
            skip "MessagePack not available for testing" unless MSGPACK_AVAILABLE_FOR_TESTS
            
            # Mock defined? to return true for MessagePack
            allow(subject).to receive(:defined?).with(anything).and_call_original
            allow(subject).to receive(:defined?).with(MessagePack).and_return(true)
          end
          
          it 'decompresses and unpacks with MessagePack' do
            # Expect MessagePack unpacking
            expect(MessagePack).to receive(:unpack).with(decompressed_data).and_return(test_result)
            
            # Call the method
            result = subject.send(:receive_results_from_child, read_pipe)
            
            # Verify result
            expect(result).to eq(test_result)
          end
        end
        
        context 'when MessagePack is not available' do
          before do
            # Mock defined? to consistently return false for MessagePack
            allow(subject).to receive(:defined?).with(anything).and_call_original
            allow(subject).to receive(:defined?).with(MessagePack).and_return(false)
          end
          
          it 'falls back to Marshal.load after decompression' do
            # Setup Marshal to load the decompressed data
            allow(Marshal).to receive(:load).with(decompressed_data).and_return(test_result)
            
            # Call the method
            result = subject.send(:receive_results_from_child, read_pipe)
            
            # Verify result
            expect(result).to eq(test_result)
          end
        end
      end
      
      context 'with error conditions' do
        let(:format_byte) { 2 } # Marshal format
        
        it 'handles timeouts gracefully' do
          # Simulate timeout
          allow(IO).to receive(:select).with([read_pipe], nil, nil, anything).and_return(nil)
          
          # Call the method
          result = subject.send(:receive_results_from_child, read_pipe)
          
          # Verify error result
          expect(result[:error]).to include("Timeout")
        end
        
        it 'handles broken pipes gracefully' do
          # Simulate pipe error
          allow(read_pipe).to receive(:read).with(1).and_raise(Errno::EPIPE.new("Broken pipe"))
          
          # Call the method
          result = subject.send(:receive_results_from_child, read_pipe)
          
          # Verify error result
          expect(result[:error]).to include("Pipe broken")
        end
      end
    end
  end
end
