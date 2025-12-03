# frozen_string_literal: true

require 'socket'
require 'timeout'
require 'fileutils'
require 'tempfile'

# Test harness for multi-process cluster tests
# Provides utilities for spawning coordinators and workers as separate processes
module ClusterTestHarness
  # Tracks all spawned processes for cleanup
  class ProcessManager
    attr_reader :processes

    def initialize
      @processes = []
      @mutex = Mutex.new
    end

    def spawn_process(cmd, env: {}, label: nil)
      # Create temp files for output capture
      stdout_file = Tempfile.new(['cluster_test_stdout', '.log'])
      stderr_file = Tempfile.new(['cluster_test_stderr', '.log'])

      pid = Process.spawn(
        env,
        *cmd,
        out: stdout_file.path,
        err: stderr_file.path
      )

      process_info = {
        pid: pid,
        cmd: cmd,
        label: label || cmd.join(' '),
        stdout_file: stdout_file,
        stderr_file: stderr_file,
        started_at: Time.now
      }

      @mutex.synchronize { @processes << process_info }
      process_info
    end

    def kill_all
      @mutex.synchronize do
        @processes.each do |proc_info|
          kill_process(proc_info)
        end
        @processes.clear
      end
    end

    def kill_process(proc_info)
      pid = proc_info[:pid]
      begin
        # First try SIGTERM for graceful shutdown
        Process.kill('TERM', pid)
        # Wait briefly for graceful shutdown
        Timeout.timeout(2) { Process.waitpid(pid) }
      rescue Errno::ESRCH
        # Process already gone
      rescue Timeout::Error
        # Force kill if still running
        begin
          Process.kill('KILL', pid)
          Process.waitpid(pid)
        rescue Errno::ESRCH, Errno::ECHILD
          # Process gone
        end
      rescue Errno::ECHILD
        # Already reaped
      ensure
        # Clean up temp files
        proc_info[:stdout_file]&.close
        proc_info[:stdout_file]&.unlink rescue nil
        proc_info[:stderr_file]&.close
        proc_info[:stderr_file]&.unlink rescue nil
      end
    end

    def read_output(proc_info)
      stdout = File.read(proc_info[:stdout_file].path) rescue ''
      stderr = File.read(proc_info[:stderr_file].path) rescue ''
      { stdout: stdout, stderr: stderr }
    end

    def process_alive?(proc_info)
      Process.kill(0, proc_info[:pid])
      true
    rescue Errno::ESRCH
      false
    end
  end

  # Port management for avoiding conflicts
  # Uses OS-assigned ephemeral ports to guarantee no conflicts
  class PortAllocator
    def initialize(base_port: nil) # base_port ignored, kept for compatibility
      @allocated = []
      @mutex = Mutex.new
    end

    def allocate(count = 1)
      @mutex.synchronize do
        ports = []
        count.times do
          port = find_available_port
          @allocated << port
          ports << port
        end
        count == 1 ? ports.first : ports
      end
    end

    def release_all
      @mutex.synchronize { @allocated.clear }
    end

    private

    def find_available_port
      # Let the OS assign an available port by binding to port 0
      server = TCPServer.new('127.0.0.1', 0)
      port = server.addr[1]
      server.close
      port
    end
  end

  # Main harness class for running cluster tests
  class Harness
    attr_reader :process_manager, :port_allocator

    def initialize
      @process_manager = ProcessManager.new
      @port_allocator = PortAllocator.new
    end

    # Wait for a port to become available (process listening)
    def wait_for_port(port, timeout: 15)
      deadline = Time.now + timeout
      loop do
        begin
          socket = TCPSocket.new('127.0.0.1', port)
          socket.close
          return true
        rescue Errno::ECONNREFUSED, Errno::ECONNRESET
          return false if Time.now > deadline
          sleep 0.05
        end
      end
    end

    # Wait for a port to be closed (process stopped listening)
    def wait_for_port_closed(port, timeout: 10)
      deadline = Time.now + timeout
      loop do
        begin
          socket = TCPSocket.new('127.0.0.1', port)
          socket.close
          return false if Time.now > deadline
          sleep 0.05
        rescue Errno::ECONNREFUSED
          return true
        end
      end
    end

    # Spawn a coordinator process
    def spawn_coordinator(example_file, mode: 'coordinator', port: nil, env: {}, wait: true)
      port ||= @port_allocator.allocate

      # Set environment variable to override default port
      full_env = env.merge('CLUSTER_PORT' => port.to_s)

      cmd = ['bundle', 'exec', 'ruby', example_file, mode]
      proc_info = @process_manager.spawn_process(cmd, env: full_env, label: "coordinator:#{port}")
      proc_info[:port] = port

      if wait
        unless wait_for_port(port, timeout: 15)
          output = @process_manager.read_output(proc_info)
          raise "Coordinator failed to start on port #{port}.\nStdout: #{output[:stdout]}\nStderr: #{output[:stderr]}"
        end
      end

      proc_info
    end

    # Spawn a worker process
    def spawn_worker(example_file, mode:, coordinator_port: nil, env: {}, wait_port: nil)
      full_env = env.dup
      full_env['CLUSTER_PORT'] = coordinator_port.to_s if coordinator_port

      cmd = ['bundle', 'exec', 'ruby', example_file, mode]
      proc_info = @process_manager.spawn_process(cmd, env: full_env, label: "worker:#{mode}")

      if wait_port
        unless wait_for_port(wait_port, timeout: 15)
          output = @process_manager.read_output(proc_info)
          raise "Worker failed to start listening on port #{wait_port}.\nStdout: #{output[:stdout]}\nStderr: #{output[:stderr]}"
        end
      else
        # Brief delay to let worker initialize
        sleep 0.3
      end

      proc_info
    end

    # Spawn a generic ruby subprocess with the example file
    def spawn_example(example_file, *args, env: {}, wait_port: nil, timeout: 30)
      cmd = ['bundle', 'exec', 'ruby', example_file, *args.map(&:to_s)]
      proc_info = @process_manager.spawn_process(cmd, env: env, label: File.basename(example_file))

      if wait_port
        unless wait_for_port(wait_port, timeout: 15)
          output = @process_manager.read_output(proc_info)
          raise "Process failed to start on port #{wait_port}.\nStdout: #{output[:stdout]}\nStderr: #{output[:stderr]}"
        end
      end

      proc_info
    end

    # Spawn a worker that retries connecting to coordinator until success or timeout
    # This is useful when coordinator ports open sequentially during pipeline execution
    def spawn_worker_with_retry(example_file, *args, env: {}, coordinator_port:, retry_interval: 2, max_retries: 30)
      # Wait for coordinator port to be available before spawning worker
      deadline = Time.now + (retry_interval * max_retries)
      until wait_for_port(coordinator_port, timeout: 1)
        return nil if Time.now > deadline
        sleep retry_interval
      end

      # Now spawn the worker
      spawn_example(example_file, *args, env: env)
    end

    # Run an example and wait for it to complete
    def run_example_to_completion(example_file, *args, env: {}, timeout: 45)
      cmd = ['bundle', 'exec', 'ruby', example_file, *args.map(&:to_s)]
      proc_info = @process_manager.spawn_process(cmd, env: env, label: File.basename(example_file))

      # Wait for process to complete
      begin
        Timeout.timeout(timeout) do
          Process.waitpid(proc_info[:pid])
        end
      rescue Timeout::Error
        @process_manager.kill_process(proc_info)
        output = @process_manager.read_output(proc_info)
        raise "Example timed out after #{timeout}s.\nStdout: #{output[:stdout]}\nStderr: #{output[:stderr]}"
      end

      output = @process_manager.read_output(proc_info)
      {
        stdout: output[:stdout],
        stderr: output[:stderr],
        success: $?.success?,
        exit_status: $?.exitstatus
      }
    end

    # Wait for output to contain expected text
    def wait_for_output(proc_info, pattern, timeout: 30)
      deadline = Time.now + timeout
      loop do
        output = @process_manager.read_output(proc_info)
        combined = output[:stdout] + output[:stderr]

        case pattern
        when Regexp
          return true if combined.match?(pattern)
        when String
          return true if combined.include?(pattern)
        end

        return false if Time.now > deadline
        sleep 0.1
      end
    end

    # Wait for worker registration by checking coordinator output
    def wait_for_workers(coordinator_proc, count:, timeout: 30)
      pattern = /Worker registered.*/ # Match worker registration messages
      deadline = Time.now + timeout

      loop do
        output = @process_manager.read_output(coordinator_proc)
        combined = output[:stdout] + output[:stderr]
        registered_count = combined.scan(/Worker registered/).size

        return true if registered_count >= count
        return false if Time.now > deadline
        sleep 0.1
      end
    end

    # Cleanup all resources
    def cleanup
      @process_manager.kill_all
      @port_allocator.release_all
    end
  end
end
