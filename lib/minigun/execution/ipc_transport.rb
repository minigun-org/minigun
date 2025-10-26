# frozen_string_literal: true

module Minigun
  module Execution
    # Handles inter-process communication via pipes and Marshal
    class IPCTransport
      attr_reader :pid

      def initialize(name: nil)
        @name = name
        @input_reader = nil
        @input_writer = nil
        @output_reader = nil
        @output_writer = nil
        @pid = nil
      end

      # Create bidirectional pipes for parent-child communication
      def create_pipes
        @input_reader, @input_writer = IO.pipe    # Parent writes → Child reads
        @output_reader, @output_writer = IO.pipe  # Child writes → Parent reads
      end

      # Close parent-side pipes (call in child process)
      def close_parent_pipes
        @input_writer&.close
        @output_reader&.close
      end

      # Close child-side pipes (call in parent process)
      def close_child_pipes
        @input_reader&.close
        @output_writer&.close
      end

      # Close all pipes
      def close_all_pipes
        @input_reader&.close rescue nil
        @input_writer&.close rescue nil
        @output_reader&.close rescue nil
        @output_writer&.close rescue nil
      end

      # Send data from parent to child
      def send_to_child(data)
        raise "No input pipe" unless @input_writer
        Marshal.dump(data, @input_writer)
        @input_writer.flush
      end

      # Receive data from child in parent
      def receive_from_child
        raise "No output pipe" unless @output_reader
        Marshal.load(@output_reader)
      rescue EOFError
        nil  # Child closed pipe
      end

      # Send data from child to parent
      def send_to_parent(data)
        raise "No output pipe" unless @output_writer
        Marshal.dump(data, @output_writer)
        @output_writer.flush
      end

      # Receive data from parent in child
      def receive_from_parent
        raise "No input pipe" unless @input_reader
        Marshal.load(@input_reader)
      rescue EOFError
        nil  # Parent closed pipe
      end

      # Send result back from child (with error handling)
      def send_result(result)
        send_to_parent({ result: result })
      end

      # Send error back from child
      def send_error(exception)
        send_to_parent({
          error: exception.message,
          backtrace: exception.backtrace&.first(10)
        })
      end

      # Receive result in parent (handles errors)
      def receive_result
        data = receive_from_child
        return nil unless data

        if data.is_a?(Hash) && data[:error]
          # Re-raise the original error
          raise data[:error]
        end

        data[:result] if data.is_a?(Hash)
      end

      # Store PID
      def set_pid(pid)
        @pid = pid
      end

      # Check if process is alive
      def alive?
        return false unless @pid
        Process.waitpid(@pid, Process::WNOHANG).nil?
      rescue Errno::ECHILD
        false
      end

      # Wait for process to complete
      def wait
        return unless @pid
        Process.wait(@pid)
        @pid = nil
      rescue Errno::ECHILD
        @pid = nil
      end

      # Terminate process
      def terminate
        return unless @pid
        Process.kill('TERM', @pid)
        wait
      rescue Errno::ESRCH, Errno::ECHILD
        @pid = nil
      end

      # Get reader/writer for direct access (if needed)
      attr_reader :input_reader, :input_writer, :output_reader, :output_writer
    end
  end
end

