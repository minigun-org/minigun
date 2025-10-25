# frozen_string_literal: true

module Minigun
  # Execution strategies for stages and pipelines
  module ExecutionStrategy
    # Base strategy interface
    class Base
      attr_reader :config

      def initialize(config = {})
        @config = config
      end

      # Execute a block with this strategy
      def execute(context, &block)
        raise NotImplementedError, "Subclasses must implement #execute"
      end

      # Cleanup after execution
      def cleanup
        # Override in subclasses if needed
      end
    end

    # Threaded execution (default, in-process)
    class Threaded < Base
      def execute(context, &block)
        Thread.new do
          context.instance_eval(&block)
        rescue => e
          log_error("Threaded execution error: #{e.message}")
          raise
        end
      end

      private

      def log_error(msg)
        Minigun.logger.error(msg)
      end
    end

    # Fork with accumulation (accumulate, then fork with batch)
    # This is what PublisherBase does - Copy-On-Write optimization
    class ForkAccumulate < Base
      def initialize(config = {})
        super
        @accumulator = []
        @mutex = Mutex.new
        @pids = []
        @max_batch_size = config[:accumulator_max_single] || 2000
        @check_interval = config[:accumulator_check_interval] || 100
      end

      # Accumulate items and fork when threshold reached
      def accumulate(item)
        @mutex.synchronize { @accumulator << item }

        if @accumulator.size >= @max_batch_size
          fork_consumer(@accumulator.dup)
          @accumulator.clear
        end
      end

      # Execute remaining items
      def execute(context, &block)
        # Process any remaining accumulated items
        unless @accumulator.empty?
          fork_consumer(@accumulator.dup)
          @accumulator.clear
        end

        wait_all
      end

      def cleanup
        wait_all
      end

      private

      def fork_consumer(items)
        return if items.empty?

        if Process.respond_to?(:fork)
          fork_consumer_process(items)
        else
          # Fallback to threads on Windows
          consume_in_thread(items)
        end
      end

      def fork_consumer_process(items)
        pid = fork do
          log_info "[CowFork:#{Process.pid}] Processing #{items.size} items"

          # Process items in forked child
          items.each do |item|
            # Execute consumer logic
            yield item if block_given?
          end

          exit! 0
        end

        @mutex.synchronize { @pids << pid }
      end

      def consume_in_thread(items)
        Thread.new do
          items.each { |item| yield item if block_given? }
        end.join
      end

      def wait_all
        @pids.each do |pid|
          Process.wait(pid)
        rescue Errno::ECHILD
          # Already exited
        end
        @pids.clear
      end

      def log_info(msg)
        Minigun.logger.info(msg)
      end
    end

    # Fork with IPC (fork upfront, communicate via sockets)
    class ForkIpc < Base
      def initialize(config = {})
        super
        @input_socket = nil
        @output_socket = nil
        @pid = nil
      end

      def execute(context, &block)
        # Create socket pair for IPC
        parent_socket, child_socket = Socket.pair(:UNIX, :STREAM, 0)

        @pid = fork do
          parent_socket.close
          @input_socket = child_socket

          log_info "[IpcFork:#{Process.pid}] Started"

          # Read from socket and process
          loop do
            data = read_message(@input_socket)
            break if data == :END_OF_STREAM

            # Execute block with data
            result = context.instance_exec(data, &block)

            # Send result back if needed
            write_message(@input_socket, result) if result
          end

          log_info "[IpcFork:#{Process.pid}] Finished"
          exit! 0
        end

        # Parent process
        child_socket.close
        @output_socket = parent_socket

        log_info "[IpcFork] Forked child process #{@pid}"
      end

      # Send data to forked process
      def send(data)
        write_message(@output_socket, data)
      end

      # Signal end of stream
      def finish
        write_message(@output_socket, :END_OF_STREAM)
      end

      def cleanup
        finish if @output_socket

        if @pid
          begin
            Process.wait(@pid)
          rescue Errno::ECHILD
            # Already exited
          end
        end

        @output_socket&.close
      end

      private

      def write_message(socket, data)
        serialized = Marshal.dump(data)
        size = [serialized.bytesize].pack('N')
        socket.write(size + serialized)
      end

      def read_message(socket)
        size_data = socket.read(4)
        return nil unless size_data

        size = size_data.unpack1('N')
        serialized = socket.read(size)
        Marshal.load(serialized)
      end

      def log_info(msg)
        Minigun.logger.info(msg)
      end
    end

    # Ractor-based execution (Ruby 3.0+)
    class Ractor < Base
      def initialize(config = {})
        super
        @ractor = nil
      end

      def execute(context, &block)
        # Check if Ractors are available
        unless defined?(::Ractor)
          raise Minigun::Error, "Ractors require Ruby 3.0+"
        end

        # Create ractor with the block
        @ractor = ::Ractor.new(block) do |blk|
          log_info "[Ractor:#{::Ractor.current}] Started"

          loop do
            data = ::Ractor.receive
            break if data == :END_OF_STREAM

            # Execute block with data
            result = blk.call(data)

            # Send result back
            ::Ractor.yield(result) if result
          end

          log_info "[Ractor:#{::Ractor.current}] Finished"
        end

        log_info "[Ractor] Created ractor #{@ractor}"
      end

      # Send data to ractor
      def send(data)
        @ractor.send(data)
      end

      # Receive result from ractor
      def receive
        ::Ractor.receive_if { |msg| msg[:from] == @ractor }
      end

      # Signal end of stream
      def finish
        @ractor.send(:END_OF_STREAM)
      end

      def cleanup
        finish if @ractor

        begin
          @ractor.take  # Wait for ractor to finish
        rescue ::Ractor::ClosedError
          # Already closed
        end
      end

      private

      def log_info(msg)
        Minigun.logger.info(msg)
      end
    end

    # Ractor with accumulation (accumulate, then send to ractors)
    # Like ForkAccumulate but with ractors instead of processes
    class RactorAccumulate < Base
      def initialize(config = {})
        super

        unless defined?(::Ractor)
          raise Minigun::Error, "Ractors require Ruby 3.0+"
        end

        @accumulator = []
        @mutex = Mutex.new
        @ractors = []
        @max_batch_size = config[:accumulator_max_single] || 2000
        @max_ractors = config[:max_ractors] || 4
      end

      # Accumulate items and process when threshold reached
      def accumulate(item)
        @mutex.synchronize { @accumulator << item }

        if @accumulator.size >= @max_batch_size
          process_batch(@accumulator.dup)
          @accumulator.clear
        end
      end

      # Execute remaining items
      def execute(context, &block)
        unless @accumulator.empty?
          process_batch(@accumulator.dup)
          @accumulator.clear
        end

        wait_all
      end

      def cleanup
        wait_all
      end

      private

      def process_batch(items)
        return if items.empty?

        # Distribute items across ractors
        items.each_slice((items.size.to_f / @max_ractors).ceil) do |batch|
          ractor = ::Ractor.new(batch) do |item_batch|
            log_info "[RactorAccumulate:#{::Ractor.current}] Processing #{item_batch.size} items"

            item_batch.each do |item|
              # Execute consumer logic
              yield item if block_given?
            end

            :done
          end

          @ractors << ractor
        end
      end

      def wait_all
        @ractors.each do |ractor|
          begin
            ractor.take  # Wait for ractor to finish
          rescue ::Ractor::ClosedError
            # Already closed
          end
        end
        @ractors.clear
      end

      def log_info(msg)
        Minigun.logger.info(msg)
      end
    end

    # Factory method to create strategy
    def self.create(type, config = {})
      case type
      when :threaded
        Threaded.new(config)
      when :fork_accumulate
        ForkAccumulate.new(config)
      when :fork_ipc
        ForkIpc.new(config)
      when :ractor
        Ractor.new(config)
      when :ractor_accumulate
        RactorAccumulate.new(config)
      else
        raise Minigun::Error, "Unknown execution strategy: #{type}"
      end
    end
  end
end

