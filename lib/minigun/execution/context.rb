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
        # CRITICAL: Ensure any previous thread is done before starting a new one
        # This prevents closure interference when contexts are reused from pool
        if @thread&.alive?
          @thread.join
        end
        
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
      def execute(&block)
        @reader, @writer = IO.pipe

        @pid = fork do
          @reader.close

          # Set process title
          Process.setproctitle("minigun:#{@name}") if Process.respond_to?(:setproctitle)

          begin
            result = block.call
            Marshal.dump(result, @writer)
          rescue => e
            Marshal.dump({ error: e }, @writer)
          ensure
            @writer.close
          end
        end

        @writer.close
        self
      end

      def join
        return nil unless @pid

        Process.wait(@pid)
        result = Marshal.load(@reader) rescue nil
        @reader.close
        @pid = nil

        if result.is_a?(Hash) && result[:error]
          raise result[:error]
        end

        result
      end

      def alive?
        return false unless @pid
        Process.waitpid(@pid, Process::WNOHANG).nil?
      rescue Errno::ECHILD
        false
      end

      def terminate
        return unless @pid
        Process.kill('TERM', @pid)
        join
      rescue Errno::ESRCH, Errno::ECHILD
        # Already dead
        @pid = nil
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
      when :thread
        ThreadContext.new(name)
      when :fork
        ForkContext.new(name)
      when :ractor
        RactorContext.new(name)
      else
        raise ArgumentError, "Unknown context type: #{type}"
      end
    end
  end
end

