# frozen_string_literal: true

require 'English'
require_relative 'base'

module Minigun
  module Stages
    # Implementation of IPC-style fork behavior
    class IpcFork < Base
      attr_reader :name, :job_id, :processes, :threads, :block

      # Constants for IPC communication
      MAX_CHUNK_SIZE = 1024 * 1024 # 1MB
      DEFAULT_PIPE_TIMEOUT = 30 # seconds
      GC_PROBABILITY = 0.1 # 10% chance of GC in child process

      def initialize(name, pipeline, config = {})
        super
        # Configuration - use existing instance variables if already set
        @max_processes = config[:processes] || config[:max_processes] || 2
        @max_threads = config[:threads] || config[:max_threads] || 5
        @max_retries = config[:max_retries] || 3
        @fork_mode = config[:fork_mode] || :auto
        @pipe_timeout = config[:pipe_timeout] || DEFAULT_PIPE_TIMEOUT
        @use_compression = config.key?(:use_compression) ? config[:use_compression] : true

        # For compatibility with the processor interface
        @processes = @max_processes
        @threads = @max_threads

        # Initialize child process tracking
        @child_processes = []
        @process_mutex = Mutex.new

        # Create thread pool for non-forking mode
        @thread_pool = Concurrent::FixedThreadPool.new(@max_threads)

        # Statistics
        @processed_count = Concurrent::AtomicFixnum.new(0)
        @failed_count = Concurrent::AtomicFixnum.new(0)
        @emitted_count = Concurrent::AtomicFixnum.new(0)

        # Get the block for this stage from the task
        @stage_block = nil

        # Check stage blocks directly
        @stage_block = @task.stage_blocks[name.to_sym] if @task.respond_to?(:stage_blocks) && @task.stage_blocks[name.to_sym]

        # Fallback to a default implementation
        @stage_block ||= proc { |items| items }
      end

      def run
        # Nothing to do on startup
      end

      def process(item)
        # In a real implementation, this would fork processes and use IPC
        # For now, just process the item directly
        puts "[IPC Fork] Processing item: #{item}"
        emit(item)
      end

      def shutdown
        # Wait for all child processes to complete
        wait_for_child_processes

        # Shut down thread pool if it exists
        if @thread_pool
          @thread_pool.shutdown
          @thread_pool.wait_for_termination
        end

        # Return processing statistics
        {
          processed: @processed_count.value,
          failed: @failed_count.value,
          emitted: @emitted_count.value
        }
      end

      def stop
        # Stop all worker processes
        @child_processes.each { |child| child[:pipe].close }
        super
      end

      private

      def fork_to_process(items)
        # Wait if we've reached max processes
        wait_for_available_process_slot if @child_processes.size >= @max_processes

        # Start a new process if forking is available and fork mode allows
        if Process.respond_to?(:fork) && @fork_mode != :never
          # Force GC before forking to reduce memory footprint
          GC.start

          # Create a pipe for parent-child communication with binary mode and close-on-exec flag
          read_pipe, write_pipe = IO.pipe
          read_pipe.binmode
          write_pipe.binmode
          read_pipe.close_on_exec = true
          write_pipe.close_on_exec = true

          pid = Process.fork do
            # In child process
            read_pipe.close

            # Run any before_fork hooks
            @task.run_hook(:before_fork, @context)

            # Set this process title for easier identification
            Process.setproctitle("minigun-ipc-#{@name}-#{Process.pid}") if Process.respond_to?(:setproctitle)

            # Process the items
            results = process_items_in_child(items)

            # Send results back to parent
            begin
              send_results_to_parent(write_pipe, results)
            rescue StandardError => e
              # Handle errors in sending results
              @logger.error("[Minigun:#{@job_id}][#{@name}] Error sending results to parent: #{e.message}")
              # Try to send error information
              begin
                write_pipe.write(Marshal.dump({ error: e.message, backtrace: e.backtrace }))
              rescue StandardError
                # Last-ditch effort to communicate failure
                write_pipe.write("ERROR: #{e.message}")
              ensure
                write_pipe.close
              end
              exit!(2)
            ensure
              write_pipe.close
            end

            # Run any after_fork hooks
            @task.run_hook(:after_fork, @context)

            # Exit cleanly
            exit!(0)
          rescue StandardError => e
            # Handle errors in child process
            begin
              write_pipe.write(Marshal.dump({ error: e.message, backtrace: e.backtrace }))
            rescue StandardError
              # Last-ditch effort to communicate failure
              write_pipe.write("ERROR: #{e.message}")
            ensure
              write_pipe.close
            end
            exit!(1)
          end

          # In parent process
          write_pipe.close

          # Track the child process
          @process_mutex.synchronize do
            @child_processes << {
              pid: pid,
              pipe: read_pipe,
              start_time: Time.now,
              items_count: items.size
            }
          end
        else
          # If forking is not available or disabled, process using thread pool
          @thread_pool.post do
            results = process_items_directly(items)
            @processed_count.increment(results[:success] || 0)
            @failed_count.increment(results[:failed] || 0)
            @emitted_count.increment(results[:emitted] || 0) if results[:emitted] && results[:emitted] > 0
          rescue StandardError => e
            @logger.error("[Minigun:#{@job_id}][#{@name}] Thread pool error: #{e.message}")
            @logger.error("[Minigun:#{@job_id}][#{@name}] #{e.backtrace.join("\n")}") if e.backtrace
            @failed_count.increment(items.size)
          end
        end
      end

      def process_items_in_child(items)
        # Store fork context for emit tracking
        Thread.current[:minigun_fork_context] = {
          emit_count: 0,
          success_count: 0,
          failed_count: 0
        }

        # Process items in batches to allow periodic GC
        items_count = items.count
        batch_size = [100, (items_count / 10.0).ceil].min

        if batch_size > 1 && items_count > batch_size
          items.each_slice(batch_size) do |batch|
            # Execute the fork block for this batch
            process_batch(batch)

            # Periodic GC to prevent memory bloat
            GC.start if rand < GC_PROBABILITY
          end
        else
          # Small enough to process as a single batch
          process_batch(items)
        end

        # Get counts from context
        context = Thread.current[:minigun_fork_context]
        success_count = context[:success_count]
        failed_count = context[:failed_count]
        emit_count = context[:emit_count]

        # Return results
        {
          success: success_count || items.size,
          failed: failed_count || 0,
          emitted: emit_count || 0
        }
      rescue StandardError => e
        @logger.error("[Minigun:#{@job_id}][#{@name}] Error in child process: #{e.message}")
        @logger.error("[Minigun:#{@job_id}][#{@name}] #{e.backtrace.join("\n")}") if e.backtrace
        {
          success: 0,
          failed: items.size,
          error: e.message,
          backtrace: e.backtrace
        }
      end

      def process_batch(batch)
        # Execute the fork block, which should call emit
        if @stage_block
          @context.instance_exec(batch, &@stage_block)
        else
          # Default behavior if no block given - emit each item
          batch.each do |item|
            emit(item)
          end
        end
      end

      def process_items_directly(items)
        # Execute the block directly without forking
        # Store fork context for emit tracking
        Thread.current[:minigun_fork_context] = {
          emit_count: 0,
          success_count: 0,
          failed_count: 0
        }

        # Process smaller batches to allow GC if needed
        items_count = items.count
        batch_size = [100, (items_count / 10.0).ceil].min

        if batch_size > 1 && items_count > batch_size
          items.each_slice(batch_size) do |batch|
            # Execute the fork block for this batch
            process_batch(batch)

            # Periodic GC to prevent memory bloat
            GC.start if rand < GC_PROBABILITY
          end
        else
          # Small enough to process as a single batch
          process_batch(items)
        end

        # Get counts from context
        context = Thread.current[:minigun_fork_context]
        success_count = context[:success_count] || items.size
        failed_count = context[:failed_count] || 0
        emit_count = context[:emit_count] || 0

        # Return results
        {
          success: success_count,
          failed: failed_count,
          emitted: emit_count
        }
      rescue StandardError => e
        @logger.error("[Minigun:#{@job_id}][#{@name}] Error in direct processing: #{e.message}")
        @logger.error("[Minigun:#{@job_id}][#{@name}] #{e.backtrace.join("\n")}") if e.backtrace
        {
          success: 0,
          failed: items.size,
          error: e.message,
          backtrace: e.backtrace
        }
      end

      def send_results_to_parent(pipe, results)
        # Serialize results
        if defined?(MessagePack)
          # Use MessagePack if available (more efficient)
          serialized = results.to_msgpack
          format = :msgpack
        else
          # Fall back to Marshal
          serialized = Marshal.dump(results)
          format = :marshal
        end

        # Compress if needed
        if @use_compression && serialized.bytesize > 1024
          compressed = Zlib::Deflate.deflate(serialized)
          # Only use compression if it's actually smaller
          if compressed.bytesize < serialized.bytesize
            serialized = compressed
            format = format == :msgpack ? :msgpack_compressed : :marshal_compressed
          end
        end

        # Send format identifier (1 byte)
        format_byte = case format
                      when :msgpack then 1
                      when :marshal then 2
                      when :msgpack_compressed then 3
                      when :marshal_compressed then 4
                      end
        pipe.write([format_byte].pack('C'))

        # For large results, send in chunks
        if serialized.bytesize > MAX_CHUNK_SIZE
          send_chunked_data(pipe, serialized)
        else
          # Send data size followed by data
          pipe.write([serialized.bytesize].pack('L'))
          pipe.write(serialized)
        end
      end

      def send_chunked_data(pipe, data)
        # Split data into chunks
        chunks = data.scan(/.{1,#{MAX_CHUNK_SIZE}}/mo)

        # Mark as chunked with total size and number of chunks
        pipe.write([0xFFFFFFFF].pack('L')) # Special marker for chunked data
        pipe.write([data.bytesize, chunks.size].pack('LL'))

        # Send each chunk
        chunks.each do |chunk|
          pipe.write([chunk.bytesize].pack('L'))
          pipe.write(chunk)
        end
      end

      def receive_results_from_child(pipe)
        # Set up non-blocking read with timeout
        ready = IO.select([pipe], nil, nil, @pipe_timeout)
        raise Timeout::Error, 'Timeout waiting for child process data' unless ready

        # Read format byte
        format_byte = pipe.read(1)
        return { error: 'Empty pipe' } unless format_byte

        format_byte = format_byte.unpack1('C')

        # Read data size
        size_data = pipe.read(4)
        return { error: 'Invalid pipe data (size)' } unless size_data

        size = size_data.unpack1('L')

        # Check if data is chunked
        if size == 0xFFFFFFFF
          # Read total size and chunk count
          _, chunk_count = pipe.read(8).unpack('LL')

          # Read and concatenate chunks
          data = ''
          chunk_count.times do
            chunk_size = pipe.read(4).unpack1('L')
            chunk = pipe.read(chunk_size)
            data << chunk
          end
        else
          # Read data directly
          data = pipe.read(size)
        end

        # Process based on format
        case format_byte
        when 1 # msgpack
          defined?(MessagePack) ? MessagePack.unpack(data) : Marshal.load(data)
        when 2 # marshal
          Marshal.load(data)
        when 3 # msgpack_compressed
          decompressed = Zlib::Inflate.inflate(data)
          defined?(MessagePack) ? MessagePack.unpack(decompressed) : Marshal.load(decompressed)
        when 4 # marshal_compressed
          Marshal.load(Zlib::Inflate.inflate(data))
        else
          { error: "Unknown format: #{format_byte}" }
        end
      rescue Timeout::Error => e
        { error: "Timeout reading from pipe: #{e.message}" }
      rescue EOFError => e
        { error: "EOF reading from pipe: #{e.message}" }
      rescue Errno::EPIPE, Errno::ECONNRESET => e
        { error: "Pipe broken: #{e.message}" }
      rescue StandardError => e
        { error: "Error reading from pipe: #{e.class}: #{e.message}", backtrace: e.backtrace }
      end

      def wait_for_available_process_slot
        loop do
          # Check child processes and collect any that have finished
          check_child_processes

          # If we have room for another process, we're done
          break if @child_processes.size < @max_processes

          # Sleep briefly before checking again
          sleep(0.1)
        end
      end

      def check_child_processes
        @process_mutex.synchronize do
          @child_processes.reject! do |child|
            # Check if the process has finished
            status = begin
              Process.waitpid(child[:pid], Process::WNOHANG)
            rescue Errno::ECHILD
              child[:pid] # Process doesn't exist anymore
            end

            if status
              # Process has finished, read the results
              begin
                results = receive_results_from_child(child[:pipe])
                begin
                  child[:pipe].close
                rescue StandardError
                  nil
                end

                # Check for errors in child
                if results[:error]
                  @logger.error("[Minigun:#{@job_id}][#{@name}] Child process error: #{results[:error]}")
                  @logger.error("[Minigun:#{@job_id}][#{@name}] #{results[:backtrace].join("\n")}") if results[:backtrace]
                  @failed_count.increment(child[:items_count])
                else
                  # Update statistics
                  @processed_count.increment(results[:success] || 0)
                  @failed_count.increment(results[:failed] || 0)
                  @emitted_count.increment(results[:emitted] || 0) if results[:emitted] && results[:emitted] > 0
                end
              rescue StandardError => e
                # Error reading from pipe
                @logger.error("[Minigun:#{@job_id}][#{@name}] Error reading from child pipe: #{e.message}")
                @logger.error("[Minigun:#{@job_id}][#{@name}] #{e.backtrace.join("\n")}") if e.backtrace
                @failed_count.increment(child[:items_count])
              ensure
                # Make sure pipe is closed
                begin
                  child[:pipe].close unless child[:pipe].closed?
                rescue StandardError
                  # Ignore errors closing pipe
                end
              end

              # Process duration for logging
              duration = Time.now - child[:start_time]
              status_code = $CHILD_STATUS.exitstatus
              if status_code == 0
                @logger.info("[Minigun:#{@job_id}][#{@name}] Child process #{child[:pid]} completed successfully in #{duration.round(2)}s")
              else
                @logger.warn("[Minigun:#{@job_id}][#{@name}] Child process #{child[:pid]} exited with status #{status_code} after #{duration.round(2)}s")
              end

              # Remove from list
              true
            else
              # Process still running
              false
            end
          end
        end
      end

      def wait_for_child_processes
        @process_mutex.synchronize do
          return if @child_processes.empty?

          @logger.info("[Minigun:#{@job_id}][#{@name}] Waiting for #{@child_processes.size} child processes to finish")
        end

        # Wait for all child processes to complete
        loop do
          @process_mutex.synchronize do
            break if @child_processes.empty?
          end

          # Check child processes and collect any that have finished
          check_child_processes

          # Sleep briefly before checking again
          sleep(0.1)
        end
      end
    end
  end
end
