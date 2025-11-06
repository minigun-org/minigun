#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

# Example: IPC Worker Spawns Nested COW Forks
#
# Demonstrates nested forking where IPC workers spawn COW fork pipelines.
# Creates a process supervision tree: Parent -> IPC workers -> COW forks
#
# Architecture:
# - Master process spawns IPC workers (persistent)
# - Each IPC worker runs a nested pipeline with COW forks (ephemeral)
# - Process tree: Master -> [IPC Worker 1, IPC Worker 2] -> [COW forks...]
# - This creates a 3-level process hierarchy

class IpcSpawnsNestedCowExample
  include Minigun::DSL

  attr_reader :results

  def initialize
    @results = []
    @results_file = "/tmp/minigun_nested_ipc_cow_#{Process.pid}.txt"
  end

  def cleanup
    FileUtils.rm_f(@results_file)
  end

  pipeline do
    # Producer generates batches in master process
    producer :generate do |output|
      puts "[Producer] Generating 4 batches in master (PID #{Process.pid})"
      4.times do |i|
        batch = (1..3).map { |j| { id: (i * 3) + j, value: ((i * 3) + j) * 10 } }
        output << batch
      end
    end

    # IPC workers receive batches and spawn nested COW forks to process items
    ipc_fork(2) do
      consumer :ipc_processor do |batch|
        ipc_pid = Process.pid
        puts "[IpcProcessor:ipc_fork] Received batch of #{batch.size} in IPC worker PID #{ipc_pid}"

        # Define a nested pipeline that uses COW forks
        # This pipeline runs INSIDE the IPC worker process
        nested_task = Class.new do
          include Minigun::DSL

          def initialize(batch, ipc_pid, results_file)
            @batch = batch
            @ipc_pid = ipc_pid
            @results_file = results_file
          end

          # Nested pipeline inside IPC worker
          pipeline do
            # Producer emits items from batch
            producer :emit_items do |output|
              puts "  [Nested:Producer] Emitting #{@batch.size} items from batch (in IPC worker #{@ipc_pid})"
              @batch.each { |item| output << item }
            end

            # COW forks process each item (spawned by IPC worker)
            cow_fork(2) do
              consumer :cow_process do |item|
                cow_pid = Process.pid
                puts "    [Nested:CowFork] Processing #{item[:id]} in COW fork PID #{cow_pid} (parent IPC worker #{@ipc_pid})"

                # Write to temp file with both PIDs
                File.open(@results_file, 'a') do |f|
                  f.flock(File::LOCK_EX)
                  f.puts "#{item[:id]}:#{@ipc_pid}:#{cow_pid}"
                  f.flock(File::LOCK_UN)
                end

                sleep 0.02 # Simulate work
              end
            end
          end
        end

        # Run the nested pipeline (COW forks spawned inside IPC worker)
        nested_task.new(batch, ipc_pid, @results_file).run
      end
    end

    after_run do
      # Read results from temp file
      if File.exist?(@results_file)
        @results = File.readlines(@results_file).map do |line|
          id, ipc_pid, cow_pid = line.strip.split(':')
          { id: id.to_i, ipc_pid: ipc_pid.to_i, cow_pid: cow_pid.to_i }
        end
      end
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  puts '=' * 80
  puts 'Example: IPC Worker Spawns Nested COW Forks'
  puts '=' * 80
  puts ''

  example = IpcSpawnsNestedCowExample.new
  begin
    example.run

    puts "\n#{'=' * 80}"
    puts 'Results:'
    puts "  Total items processed: #{example.results.size} (expected: 12)"

    ipc_pids = example.results.map { |r| r[:ipc_pid] }.uniq.sort
    cow_pids = example.results.map { |r| r[:cow_pid] }.uniq.sort

    puts "  IPC worker PIDs: #{ipc_pids.join(', ')} (#{ipc_pids.size} persistent workers)"
    puts "  COW fork PIDs: #{cow_pids.size} ephemeral forks (spawned by IPC workers)"

    success = example.results.size == 12 &&
              example.results.map { |r| r[:id] }.sort == (1..12).to_a

    puts "  Status: #{success ? '✓ SUCCESS' : '✗ FAILED'}"
    puts '=' * 80
    puts ''
    puts 'Process Hierarchy:'
    puts "  Master (#{Process.pid})"
    puts "    └─> IPC Workers (#{ipc_pids.join(', ')})"
    puts "         └─> COW Forks (#{cow_pids.size} ephemeral processes)"
    puts ''
    puts 'Key Points:'
    puts '  - 3-level process hierarchy created'
    puts '  - IPC workers are persistent (parent)'
    puts '  - COW forks are ephemeral (children of IPC workers)'
    puts '  - Nested pipelines enable complex process topologies'
    puts '  - Requires process supervision for proper cleanup'
    puts '  - Orphaned processes if IPC worker dies unexpectedly'
    puts '=' * 80
  rescue NotImplementedError => e
    puts "\nForking not available on this platform: #{e.message}"
    puts '(This is expected on Windows)'
  ensure
    example.cleanup
  end
end
