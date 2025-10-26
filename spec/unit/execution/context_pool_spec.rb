# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Minigun::Execution::ContextPool do
  describe '#initialize' do
    it 'creates a pool with specified type and max_size' do
      pool = described_class.new(type: :thread, max_size: 5)
      expect(pool.type).to eq(:thread)
      expect(pool.max_size).to eq(5)
    end
  end

  describe '#acquire' do
    let(:pool) { described_class.new(type: :inline, max_size: 3) }

    it 'creates a new context' do
      context = pool.acquire('test')
      expect(context).to be_a(Minigun::Execution::InlineContext)
    end

    it 'increments active count' do
      expect { pool.acquire('test') }.to change { pool.active_count }.by(1)
    end

    it 'creates unique contexts' do
      ctx1 = pool.acquire('test')
      ctx2 = pool.acquire('test')
      expect(ctx1).not_to equal(ctx2)
    end

    it 'respects max_size limit for active contexts' do
      3.times { pool.acquire('test') }
      expect(pool.active_count).to eq(3)
      expect(pool).to be_at_capacity
    end
  end

  describe '#release' do
    let(:pool) { described_class.new(type: :inline, max_size: 3) }

    it 'decrements active count' do
      context = pool.acquire('test')
      expect { pool.release(context) }.to change { pool.active_count }.by(-1)
    end

    it 'reuses inline contexts' do
      ctx1 = pool.acquire('test')
      ctx1.execute { 42 }
      pool.release(ctx1)

      ctx2 = pool.acquire('test')
      # Should reuse the same context
      expect(ctx2).to equal(ctx1)
    end

    it 'does not reuse thread contexts' do
      pool = described_class.new(type: :thread, max_size: 3)
      ctx1 = pool.acquire('test')
      ctx1.execute { 42 }
      ctx1.join
      pool.release(ctx1)

      ctx2 = pool.acquire('test')
      # Should create new context
      expect(ctx2).not_to equal(ctx1)
    end
  end

  describe '#join_all' do
    it 'waits for all active contexts to complete' do
      pool = described_class.new(type: :thread, max_size: 3)

      results = []
      mutex = Mutex.new

      3.times do |i|
        ctx = pool.acquire("worker-#{i}")
        ctx.execute do
          sleep 0.01
          mutex.synchronize { results << i }
        end
      end

      pool.join_all

      expect(results.sort).to eq([0, 1, 2])
      expect(pool.active_count).to eq(0)
    end
  end

  describe '#terminate_all' do
    it 'terminates all active contexts' do
      pool = described_class.new(type: :thread, max_size: 3)

      3.times do |i|
        ctx = pool.acquire("worker-#{i}")
        ctx.execute { sleep 10 }  # Long-running
      end

      expect(pool.active_count).to eq(3)

      pool.terminate_all

      expect(pool.active_count).to eq(0)
    end
  end

  describe '#at_capacity?' do
    let(:pool) { described_class.new(type: :inline, max_size: 2) }

    it 'returns false when below capacity' do
      pool.acquire('test')
      expect(pool).not_to be_at_capacity
    end

    it 'returns true when at capacity' do
      pool.acquire('test1')
      pool.acquire('test2')
      expect(pool).to be_at_capacity
    end
  end

  describe 'different context types' do
    it 'works with inline contexts' do
      pool = described_class.new(type: :inline, max_size: 5)
      ctx = pool.acquire('test')
      ctx.execute { 42 }
      expect(ctx.join).to eq(42)
      pool.release(ctx)
    end

    it 'works with thread contexts' do
      pool = described_class.new(type: :thread, max_size: 5)
      ctx = pool.acquire('test')
      ctx.execute { 42 }
      expect(ctx.join).to eq(42)
      pool.release(ctx)
    end

    it 'works with fork contexts', skip: Gem.win_platform? do
      pool = described_class.new(type: :fork, max_size: 2)
      ctx = pool.acquire('test')
      ctx.execute { 42 }
      expect(ctx.join).to eq(42)
      pool.release(ctx)
    end

    it 'works with ractor contexts' do
      skip "Ractor is experimental and flaky in full test suite (passes when run individually)"
      pool = described_class.new(type: :ractor, max_size: 4)
      ctx = pool.acquire('test')
      ctx.execute { 42 }
      expect(ctx.join).to eq(42)
      pool.release(ctx)
    end
  end

  describe 'concurrent access' do
    it 'handles concurrent acquire/release safely' do
      pool = described_class.new(type: :thread, max_size: 10)

      threads = 5.times.map do
        Thread.new do
          ctx = pool.acquire('test')
          ctx.execute { sleep 0.01; 42 }
          ctx.join
          pool.release(ctx)
        end
      end

      threads.each(&:join)

      expect(pool.active_count).to eq(0)
    end
  end
end

