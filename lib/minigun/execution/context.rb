# frozen_string_literal: true

module Minigun
  module Execution
    # Base class for execution contexts
    # Provides abstraction over thread/fork/ractor execution
    class Context
      attr_reader :name, :type

      def initialize(name)
        @name = name
        @type = self.class.name.split('::').last.sub('Context', '').downcase.to_sym
      end

      # Execute code in this context (non-blocking)
      def execute(&block)
        raise NotImplementedError, "#{self.class}#execute must be implemented"
      end

      # Wait for this context to complete
      def join
        raise NotImplementedError, "#{self.class}#join must be implemented"
      end

      # Check if context is alive
      def alive?
        raise NotImplementedError, "#{self.class}#alive? must be implemented"
      end

      # Terminate this context
      def terminate
        raise NotImplementedError, "#{self.class}#terminate must be implemented"
      end
    end

    # Inline execution (same thread, no concurrency)
    class InlineContext < Context
      def execute(&block)
        @result = block.call
        @executed = true
        self
      end

      def join
        @result
      end

      def alive?
        false # Inline execution completes immediately
      end

      def terminate
        # No-op for inline execution
      end
    end

    # Thread-based execution
    class ThreadContext < Context
      def execute(&block)
        @thread = Thread.new do
          Thread.current.name = @name if Thread.current.respond_to?(:name=)
          block.call
        end
        self
      end

      def join
        @thread&.value  # Returns the value, not the thread
      end

      def alive?
        @thread&.alive? || false
      end

      def terminate
        @thread&.kill
        @thread&.join  # Wait for thread to actually die
      end
    end

    # Fork-based execution (process)
    class ForkContext < Context
      def initialize(name)
        super(name)
        require_relative 'ipc_transport'
        @transport = IPCTransport.new(name: name)
      end

      def execute(&block)
        @transport.create_pipes

        pid = fork do
          @transport.close_parent_pipes
          Process.setproctitle("minigun:#{@name}") if Process.respond_to?(:setproctitle)

          begin
            result = block.call
            @transport.send_result(result)
          rescue => e
            @transport.send_error(e)
          ensure
            @transport.close_all_pipes
          end
        end

        @transport.set_pid(pid)
        @transport.close_child_pipes
        self
      end

      def join
        result = @transport.receive_result
        @transport.wait
        @transport.close_all_pipes
        result
      end

      def alive?
        @transport.alive?
      end

      def terminate
        @transport.terminate
        @transport.close_all_pipes
      end
    end

    # Process Pool execution (IPC) - PERSISTENT WORKERS
    # Uses IPCTransport for bidirectional communication with long-lived worker
    class ProcessPoolContext < Context
      def initialize(name)
        super(name)
        require_relative 'ipc_transport'
        @transport = IPCTransport.new(name: "worker-#{name}")
      end

      # Spawn a persistent worker process
      def spawn_worker
        return if @transport.pid  # Already spawned

        @transport.create_pipes

        pid = fork do
          @transport.close_parent_pipes
          Process.setproctitle("minigun:worker:#{@name}") if Process.respond_to?(:setproctitle)

          # Worker loop: receive items, process, send results
          loop do
            begin
              data = @transport.receive_from_parent
              break if data == :SHUTDOWN || data.nil?

              # Execute the block (data is a Proc)
              result = data.call if data.is_a?(Proc)
              @transport.send_result(result)
            rescue => e
              @transport.send_error(e)
            end
          end

          @transport.close_all_pipes
        end

        @transport.set_pid(pid)
        @transport.close_child_pipes
      end

      # Execute a block in the worker process (send via IPC)
      def execute(&block)
        spawn_worker unless @transport.pid
        @transport.send_to_child(block)
        self
      end

      # Wait for and return result from worker
      def join
        @transport.receive_result
      end

      def alive?
        @transport.alive?
      end

      def terminate
        begin
          @transport.send_to_child(:SHUTDOWN) if @transport.alive?
        rescue
          # Pipe may be closed, ignore
        end
        
        @transport.terminate
        @transport.close_all_pipes
      end
    end

    # Ractor-based execution
    class RactorContext < Context
      def execute(&block)
        begin
          @ractor = Ractor.new(name: @name, &block)
          @fallback = nil
        rescue NameError, NoMethodError
          # Ractors not available, fall back to thread
          warn "[Minigun] Ractors not available, falling back to ThreadContext"
          @fallback = ThreadContext.new(@name)
          @fallback.execute(&block)
        end
        self
      end

      def join
        if @fallback
          @fallback.join
        else
          @ractor&.take
        end
      end

      def alive?
        if @fallback
          @fallback.alive?
        else
          # Ractors don't have direct alive check
          @alive ||= true
        end
      end

      def terminate
        if @fallback
          @fallback.terminate
        else
          # Ractors can't be killed directly
          # Would need to send shutdown message
          @alive = false
        end
      end
    end

    # Factory method for creating contexts
    def self.create_context(type, name)
      case type
      when :inline
        InlineContext.new(name)
      when :thread, :threads
        ThreadContext.new(name)
      when :fork, :forks  # COW fork (one-time use, process_per_batch)
        ForkContext.new(name)
      when :process, :processes  # IPC process pool (persistent workers, processes(N))
        ProcessPoolContext.new(name)
      when :ractor, :ractors
        RactorContext.new(name)
      else
        raise ArgumentError, "Unknown context type: #{type}"
      end
    end
  end
end

