# frozen_string_literal: true

require 'socket'
require 'timeout'
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
        @processes.each { |proc_info| kill_process(proc_info) }
        @processes.clear
      end
    end

    def kill_process(proc_info)
      pid = proc_info[:pid]
      begin
        # Windows doesn't support TERM signal, use KILL directly
        if Gem.win_platform?
          Process.kill('KILL', pid)
        else
          Process.kill('TERM', pid)
          Timeout.timeout(2) { Process.waitpid(pid) }
        end
      rescue Errno::ESRCH, Errno::EINVAL
        # Process already gone (ESRCH on Unix, EINVAL can occur on Windows)
      rescue Timeout::Error
        begin
          Process.kill('KILL', pid)
          Process.waitpid(pid)
        rescue Errno::ESRCH, Errno::ECHILD, Errno::EINVAL
          # Process gone
        end
      rescue Errno::ECHILD
        # Already reaped
      ensure
        proc_info[:stdout_file]&.close
        begin
          proc_info[:stdout_file]&.unlink
        rescue StandardError
          nil
        end
        proc_info[:stderr_file]&.close
        begin
          proc_info[:stderr_file]&.unlink
        rescue StandardError
          nil
        end
      end
    end

    def read_output(proc_info)
      stdout = begin
        File.read(proc_info[:stdout_file].path)
      rescue StandardError
        ''
      end
      stderr = begin
        File.read(proc_info[:stderr_file].path)
      rescue StandardError
        ''
      end
      { stdout: stdout, stderr: stderr }
    end

    def process_alive?(proc_info)
      Process.kill(0, proc_info[:pid])
      true
    rescue Errno::ESRCH
      false
    end
  end

  # Port allocation using OS-assigned ephemeral ports
  # Keeps sockets open until release to prevent race conditions
  class PortAllocator
    def initialize
      @allocated = []
      @servers = []
      @mutex = Mutex.new
    end

    def allocate(count = 1)
      @mutex.synchronize do
        ports = count.times.map do
          server = TCPServer.new('127.0.0.1', 0)
          port = server.addr[1]
          @servers << server
          @allocated << port
          port
        end
        count == 1 ? ports.first : ports
      end
    end

    # Release a specific port (close its socket so subprocess can bind)
    def release(port)
      @mutex.synchronize do
        idx = @allocated.index(port)
        return unless idx

        @servers[idx]&.close
        @servers.delete_at(idx)
        @allocated.delete_at(idx)
      end
    end

    def release_all
      @mutex.synchronize do
        @servers.each do |s|
          s&.close
        rescue StandardError # rubocop:disable Lint/SuppressedException
        end
        @servers.clear
        @allocated.clear
      end
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
        socket = TCPSocket.new('127.0.0.1', port)
        socket.close
        return true
      rescue Errno::ECONNREFUSED, Errno::ECONNRESET
        return false if Time.now > deadline

        sleep 0.05
      end
    end

    # Spawn a generic ruby subprocess with the example file
    def spawn_example(example_file, *args, env: {}, wait_port: nil)
      # Release the port just before spawning so subprocess can bind
      @port_allocator.release(wait_port) if wait_port

      cmd = ['bundle', 'exec', 'ruby', example_file, *args.map(&:to_s)]
      proc_info = @process_manager.spawn_process(cmd, env: env, label: File.basename(example_file))

      if wait_port && !wait_for_port(wait_port, timeout: 15)
        output = @process_manager.read_output(proc_info)
        raise "Process failed to start on port #{wait_port}.\nStdout: #{output[:stdout]}\nStderr: #{output[:stderr]}"
      end

      proc_info
    end

    # Spawn a worker that waits for coordinator port before starting
    def spawn_worker_with_retry(example_file, *, coordinator_port:, env: {}, retry_interval: 0.2, max_retries: 150)
      deadline = Time.now + (retry_interval * max_retries)
      until wait_for_port(coordinator_port, timeout: 0.1)
        return nil if Time.now > deadline

        sleep retry_interval
      end
      spawn_example(example_file, *, env: env)
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

        return false unless @process_manager.process_alive?(proc_info)
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
