# frozen_string_literal: true

require 'spec_helper'
require_relative '../../../lib/minigun/execution/context'

RSpec.describe Minigun::Execution::Context do
  describe '.create_context' do
    it 'creates InlineContext for :inline type' do
      context = Minigun::Execution.create_context(:inline, 'test')
      expect(context).to be_a(Minigun::Execution::InlineContext)
      expect(context.name).to eq('test')
    end

    it 'creates ThreadContext for :thread type' do
      context = Minigun::Execution.create_context(:thread, 'test')
      expect(context).to be_a(Minigun::Execution::ThreadContext)
    end

    it 'creates ForkContext for :fork type' do
      context = Minigun::Execution.create_context(:fork, 'test')
      expect(context).to be_a(Minigun::Execution::ForkContext)
    end

    it 'creates RactorContext for :ractor type' do
      context = Minigun::Execution.create_context(:ractor, 'test')
      expect(context).to be_a(Minigun::Execution::RactorContext)
    end

    it 'raises error for unknown type' do
      expect {
        Minigun::Execution.create_context(:unknown, 'test')
      }.to raise_error(ArgumentError, /Unknown context type/)
    end
  end
end

RSpec.describe Minigun::Execution::InlineContext do
  let(:context) { described_class.new('test_inline') }

  describe '#execute' do
    it 'executes block immediately' do
      result = nil
      context.execute { result = 42 }
      expect(result).to eq(42)
    end

    it 'returns self for chaining' do
      expect(context.execute { 1 }).to eq(context)
    end
  end

  describe '#join' do
    it 'returns the result of executed block' do
      context.execute { 42 }
      expect(context.join).to eq(42)
    end
  end

  describe '#alive?' do
    it 'returns false since inline execution completes immediately' do
      context.execute { 1 }
      expect(context.alive?).to be false
    end
  end

  describe '#terminate' do
    it 'does nothing for inline execution' do
      context.execute { 1 }
      expect { context.terminate }.not_to raise_error
    end
  end

  describe '#type' do
    it 'returns :inline' do
      expect(context.type).to eq(:inline)
    end
  end
end

RSpec.describe Minigun::Execution::ThreadContext do
  let(:context) { described_class.new('test_thread') }

  describe '#execute' do
    it 'spawns a thread' do
      result = []
      context.execute { result << 42 }
      context.join
      expect(result).to eq([42])
    end

    it 'returns self for chaining' do
      expect(context.execute { 1 }).to eq(context)
    end
  end

  describe '#join' do
    it 'waits for thread to complete and returns result' do
      context.execute { sleep 0.01; 42 }
      expect(context.join).to eq(42)
    end
  end

  describe '#alive?' do
    it 'returns true while thread is running' do
      context.execute { sleep 0.1 }
      expect(context.alive?).to be true
      context.join
      expect(context.alive?).to be false
    end

    it 'returns false if thread completed' do
      context.execute { 1 }
      context.join
      expect(context.alive?).to be false
    end
  end

  describe '#terminate' do
    it 'kills the thread' do
      context.execute { sleep 10 }
      expect(context.alive?).to be true
      context.terminate
      expect(context.alive?).to be false
    end
  end

  describe '#type' do
    it 'returns :thread' do
      expect(context.type).to eq(:thread)
    end
  end
end

RSpec.describe Minigun::Execution::ForkContext do
  let(:context) { described_class.new('test_fork') }

  describe '#execute' do
    it 'spawns a process', skip: Gem.win_platform? do
      context.execute { exit 0 }
      expect(context.join).to be_nil
    end

    it 'returns self for chaining', skip: Gem.win_platform? do
      result = context.execute { 1 }
      context.join
      expect(result).to eq(context)
    end
  end

  describe '#join', skip: Gem.win_platform? do
    it 'waits for process to complete and returns result' do
      context.execute { 42 }
      expect(context.join).to eq(42)
    end

    it 'propagates errors from child process' do
      context.execute { raise StandardError, "test error" }
      expect { context.join }.to raise_error(StandardError, "test error")
    end
  end

  describe '#alive?', skip: Gem.win_platform? do
    it 'returns true while process is running' do
      context.execute { sleep 0.5 }
      expect(context.alive?).to be true
      context.terminate
    end

    it 'returns false if process completed' do
      context.execute { 1 }
      context.join
      expect(context.alive?).to be false
    end
  end

  describe '#terminate', skip: Gem.win_platform? do
    it 'kills the process' do
      context.execute { sleep 10 }
      expect(context.alive?).to be true
      context.terminate
      expect(context.alive?).to be false
    end
  end

  describe '#type' do
    it 'returns :fork' do
      expect(context.type).to eq(:fork)
    end
  end
end

RSpec.describe Minigun::Execution::RactorContext do
  let(:context) { described_class.new('test_ractor') }

  describe '#execute' do
    it 'spawns a ractor or falls back to thread' do
      context.execute { 42 }
      result = context.join
      # Either ractor worked or thread fallback worked
      expect(result).to eq(42)
    end
  end

  describe '#join' do
    it 'waits for ractor to complete and returns result' do
      context.execute { 42 }
      result = context.join
      expect(result).to eq(42)
    end
  end

  describe '#type' do
    it 'returns :ractor' do
      expect(context.type).to eq(:ractor)
    end
  end
end

RSpec.describe 'ExecutionContext integration' do
  describe 'parallel execution' do
    it 'runs multiple contexts in parallel' do
      results = []
      mutex = Mutex.new

      contexts = 3.times.map do |i|
        Minigun::Execution.create_context(:thread, "worker-#{i}")
      end

      contexts.each_with_index do |ctx, i|
        ctx.execute do
          sleep 0.01
          mutex.synchronize { results << i }
        end
      end

      contexts.each(&:join)

      expect(results.sort).to eq([0, 1, 2])
    end
  end

  describe 'mixed context types' do
    it 'can mix inline and thread contexts' do
      inline_ctx = Minigun::Execution.create_context(:inline, 'inline')
      thread_ctx = Minigun::Execution.create_context(:thread, 'thread')

      inline_ctx.execute { 'inline' }
      thread_ctx.execute { 'thread' }

      expect(inline_ctx.join).to eq('inline')
      expect(thread_ctx.join).to eq('thread')
    end
  end

  describe 'error handling' do
    it 'propagates errors from thread contexts' do
      context = Minigun::Execution.create_context(:thread, 'error_test')

      context.execute { raise StandardError, "boom" }

      expect { context.join }.to raise_error(StandardError, "boom")
    end

    it 'propagates errors from fork contexts', skip: Gem.win_platform? do
      context = Minigun::Execution.create_context(:fork, 'error_test')

      context.execute { raise StandardError, "boom" }

      expect { context.join }.to raise_error(StandardError, "boom")
    end
  end
end

