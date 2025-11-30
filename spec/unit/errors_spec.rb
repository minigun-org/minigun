# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Minigun Error Classes' do
  describe Minigun::Error do
    it 'inherits from StandardError' do
      expect(Minigun::Error.superclass).to eq(StandardError)
    end

    it 'accepts a message' do
      error = Minigun::Error.new('test message')
      expect(error.message).to eq('test message')
    end

    it 'accepts context kwargs' do
      error = Minigun::Error.new('test', foo: 'bar', baz: 123)
      expect(error.context).to eq(foo: 'bar', baz: 123)
    end

    it 'provides detailed_message with context' do
      error = Minigun::Error.new('test message', foo: 'bar')
      expect(error.detailed_message).to include('test message')
      expect(error.detailed_message).to include('foo="bar"')
    end

    it 'returns plain message when no context' do
      error = Minigun::Error.new('test message')
      expect(error.detailed_message).to eq('test message')
    end
  end

  describe 'Configuration Errors' do
    describe Minigun::ConfigurationError do
      it 'inherits from Minigun::Error' do
        expect(Minigun::ConfigurationError.superclass).to eq(Minigun::Error)
      end
    end

    describe Minigun::StageNameConflictError do
      it 'inherits from ConfigurationError' do
        expect(Minigun::StageNameConflictError.superclass).to eq(Minigun::ConfigurationError)
      end

      it 'provides stage_name and pipeline_name attributes' do
        error = Minigun::StageNameConflictError.new(
          stage_name: :processor,
          pipeline_name: 'main'
        )
        expect(error.stage_name).to eq(:processor)
        expect(error.pipeline_name).to eq('main')
      end

      it 'generates a default message from attributes' do
        error = Minigun::StageNameConflictError.new(
          stage_name: :processor,
          pipeline_name: 'main'
        )
        expect(error.message).to include('processor')
        expect(error.message).to include('main')
      end

      it 'accepts a custom message' do
        error = Minigun::StageNameConflictError.new('custom message')
        expect(error.message).to eq('custom message')
      end
    end

    describe Minigun::AmbiguousRoutingError do
      it 'inherits from ConfigurationError' do
        expect(Minigun::AmbiguousRoutingError.superclass).to eq(Minigun::ConfigurationError)
      end

      it 'provides stage_name and candidates attributes' do
        error = Minigun::AmbiguousRoutingError.new(
          stage_name: :transform,
          candidates: %w[pipeline_a.transform pipeline_b.transform]
        )
        expect(error.stage_name).to eq(:transform)
        expect(error.candidates).to eq(%w[pipeline_a.transform pipeline_b.transform])
      end

      it 'generates a default message' do
        error = Minigun::AmbiguousRoutingError.new(
          stage_name: :transform,
          candidates: %w[a b]
        )
        expect(error.message).to include('transform')
        expect(error.message).to include('2 matches')
      end
    end

    describe Minigun::InvalidOptionError do
      it 'inherits from ConfigurationError' do
        expect(Minigun::InvalidOptionError.superclass).to eq(Minigun::ConfigurationError)
      end

      it 'provides option_name, value, and expected attributes' do
        error = Minigun::InvalidOptionError.new(
          option_name: :restart_policy,
          value: :invalid,
          expected: ':never, :transient, :permanent'
        )
        expect(error.option_name).to eq(:restart_policy)
        expect(error.value).to eq(:invalid)
        expect(error.expected).to eq(':never, :transient, :permanent')
      end
    end
  end

  describe 'Pipeline Errors' do
    describe Minigun::PipelineError do
      it 'inherits from Minigun::Error' do
        expect(Minigun::PipelineError.superclass).to eq(Minigun::Error)
      end

      it 'provides pipeline_name attribute' do
        error = Minigun::PipelineError.new('test', pipeline_name: 'main')
        expect(error.pipeline_name).to eq('main')
      end
    end

    describe Minigun::CyclicDependencyError do
      it 'inherits from PipelineError' do
        expect(Minigun::CyclicDependencyError.superclass).to eq(Minigun::PipelineError)
      end

      it 'provides from_stage and to_stage attributes' do
        error = Minigun::CyclicDependencyError.new(
          from_stage: :a,
          to_stage: :b
        )
        expect(error.from_stage).to eq(:a)
        expect(error.to_stage).to eq(:b)
      end

      it 'generates a default message' do
        error = Minigun::CyclicDependencyError.new(
          from_stage: :a,
          to_stage: :b
        )
        expect(error.message).to include('a')
        expect(error.message).to include('b')
        expect(error.message).to include('cycle')
      end
    end

    describe Minigun::UnresolvedReferenceError do
      it 'inherits from PipelineError' do
        expect(Minigun::UnresolvedReferenceError.superclass).to eq(Minigun::PipelineError)
      end

      it 'provides reference and available_stages attributes' do
        error = Minigun::UnresolvedReferenceError.new(
          pipeline_name: 'main',
          reference: :missing,
          available_stages: %i[a b c]
        )
        expect(error.reference).to eq(:missing)
        expect(error.available_stages).to eq(%i[a b c])
      end
    end

    describe Minigun::SerializationError do
      it 'inherits from PipelineError' do
        expect(Minigun::SerializationError.superclass).to eq(Minigun::PipelineError)
      end

      it 'provides item_class and original_error attributes' do
        original = TypeError.new('cannot serialize')
        error = Minigun::SerializationError.new(
          item_class: 'Proc',
          original_error: original
        )
        expect(error.item_class).to eq('Proc')
        expect(error.original_error).to eq(original)
      end
    end
  end

  describe 'Execution Errors' do
    describe Minigun::ExecutionError do
      it 'inherits from Minigun::Error' do
        expect(Minigun::ExecutionError.superclass).to eq(Minigun::Error)
      end
    end

    describe Minigun::StageError do
      it 'inherits from ExecutionError' do
        expect(Minigun::StageError.superclass).to eq(Minigun::ExecutionError)
      end

      it 'provides stage_name attribute' do
        error = Minigun::StageError.new('test', stage_name: :processor)
        expect(error.stage_name).to eq(:processor)
      end
    end

    describe Minigun::ItemProcessingError do
      it 'inherits from StageError' do
        expect(Minigun::ItemProcessingError.superclass).to eq(Minigun::StageError)
      end

      it 'provides item and original_error attributes' do
        original = RuntimeError.new('boom')
        original.set_backtrace(['line1', 'line2'])
        error = Minigun::ItemProcessingError.new(
          stage_name: :processor,
          item: { id: 1 },
          original_error: original
        )
        expect(error.item).to eq({ id: 1 })
        expect(error.original_error).to eq(original)
      end

      it 'preserves original error backtrace' do
        original = RuntimeError.new('boom')
        original.set_backtrace(['line1', 'line2'])
        error = Minigun::ItemProcessingError.new(
          stage_name: :processor,
          item: { id: 1 },
          original_error: original
        )
        expect(error.backtrace).to eq(['line1', 'line2'])
      end
    end

    describe Minigun::RetryExhaustedError do
      it 'inherits from StageError' do
        expect(Minigun::RetryExhaustedError.superclass).to eq(Minigun::StageError)
      end

      it 'provides attempts and original_error attributes' do
        original = RuntimeError.new('network error')
        error = Minigun::RetryExhaustedError.new(
          stage_name: :api_call,
          attempts: 3,
          original_error: original
        )
        expect(error.attempts).to eq(3)
        expect(error.original_error).to eq(original)
      end

      it 'generates a default message' do
        original = RuntimeError.new('network error')
        error = Minigun::RetryExhaustedError.new(
          attempts: 3,
          original_error: original
        )
        expect(error.message).to include('3 attempts')
        expect(error.message).to include('network error')
      end
    end

    describe Minigun::HookError do
      it 'inherits from ExecutionError' do
        expect(Minigun::HookError.superclass).to eq(Minigun::ExecutionError)
      end

      it 'provides hook_type, stage_name, and original_error attributes' do
        original = RuntimeError.new('hook failed')
        error = Minigun::HookError.new(
          hook_type: :before,
          stage_name: :processor,
          original_error: original
        )
        expect(error.hook_type).to eq(:before)
        expect(error.stage_name).to eq(:processor)
        expect(error.original_error).to eq(original)
      end

      it 'generates a default message' do
        original = RuntimeError.new('hook failed')
        error = Minigun::HookError.new(
          hook_type: :before,
          stage_name: :processor,
          original_error: original
        )
        expect(error.message).to include('before')
        expect(error.message).to include('processor')
        expect(error.message).to include('hook failed')
      end

      it 'works without stage_name' do
        original = RuntimeError.new('hook failed')
        error = Minigun::HookError.new(
          hook_type: :before_run,
          original_error: original
        )
        expect(error.message).to include('before_run')
        expect(error.stage_name).to be_nil
      end
    end

    describe Minigun::CircuitBreakerOpenError do
      it 'inherits from ExecutionError' do
        expect(Minigun::CircuitBreakerOpenError.superclass).to eq(Minigun::ExecutionError)
      end

      it 'provides circuit_name and retry_after attributes' do
        error = Minigun::CircuitBreakerOpenError.new(
          circuit_name: :api,
          retry_after: 30.5
        )
        expect(error.circuit_name).to eq(:api)
        expect(error.retry_after).to eq(30.5)
      end

      it 'generates a default message' do
        error = Minigun::CircuitBreakerOpenError.new(
          circuit_name: :api,
          retry_after: 30.5
        )
        expect(error.message).to include('api')
        expect(error.message).to include('30.5')
      end
    end
  end
end

RSpec.describe 'Minigun Cluster Error Classes' do
  describe Minigun::ClusterError do
    it 'inherits from Minigun::Error' do
      expect(Minigun::ClusterError.superclass).to eq(Minigun::Error)
    end

    it 'is aliased as Minigun::Cluster::Error' do
      expect(Minigun::Cluster::Error).to eq(Minigun::ClusterError)
    end
  end

  describe Minigun::ClusterConnectionError do
    it 'inherits from ClusterError' do
      expect(Minigun::ClusterConnectionError.superclass).to eq(Minigun::ClusterError)
    end

    it 'is aliased as Minigun::Cluster::ConnectionError' do
      expect(Minigun::Cluster::ConnectionError).to eq(Minigun::ClusterConnectionError)
    end

    it 'provides uri and original_error attributes' do
      original = DRb::DRbConnError.new('connection refused')
      error = Minigun::Cluster::ConnectionError.new(
        uri: 'druby://localhost:9000',
        original_error: original
      )
      expect(error.uri).to eq('druby://localhost:9000')
      expect(error.original_error).to eq(original)
    end

    it 'generates a default message' do
      original = DRb::DRbConnError.new('connection refused')
      error = Minigun::Cluster::ConnectionError.new(
        uri: 'druby://localhost:9000',
        original_error: original
      )
      expect(error.message).to include('druby://localhost:9000')
      expect(error.message).to include('connection refused')
    end
  end

  describe Minigun::ClusterWorkerNotFoundError do
    it 'inherits from ClusterError' do
      expect(Minigun::ClusterWorkerNotFoundError.superclass).to eq(Minigun::ClusterError)
    end

    it 'is aliased as Minigun::Cluster::WorkerNotFoundError' do
      expect(Minigun::Cluster::WorkerNotFoundError).to eq(Minigun::ClusterWorkerNotFoundError)
    end

    it 'provides stage_name and available_stages attributes' do
      error = Minigun::Cluster::WorkerNotFoundError.new(
        stage_name: :missing,
        available_stages: %i[processor consumer]
      )
      expect(error.stage_name).to eq(:missing)
      expect(error.available_stages).to eq(%i[processor consumer])
    end
  end

  describe Minigun::ClusterDeliveryError do
    it 'inherits from ClusterError' do
      expect(Minigun::ClusterDeliveryError.superclass).to eq(Minigun::ClusterError)
    end

    it 'is aliased as Minigun::Cluster::DeliveryError' do
      expect(Minigun::Cluster::DeliveryError).to eq(Minigun::ClusterDeliveryError)
    end

    it 'provides item_id, attempts, and last_error attributes' do
      original = RuntimeError.new('worker crashed')
      error = Minigun::Cluster::DeliveryError.new(
        item_id: 'item-123',
        attempts: 3,
        last_error: original
      )
      expect(error.item_id).to eq('item-123')
      expect(error.attempts).to eq(3)
      expect(error.last_error).to eq(original)
    end

    it 'generates a default message' do
      error = Minigun::Cluster::DeliveryError.new(
        item_id: 'item-123',
        attempts: 3
      )
      expect(error.message).to include('item-123')
      expect(error.message).to include('3 attempts')
    end
  end

  describe Minigun::ClusterTimeoutError do
    it 'inherits from ClusterError' do
      expect(Minigun::ClusterTimeoutError.superclass).to eq(Minigun::ClusterError)
    end

    it 'is aliased as Minigun::Cluster::TimeoutError' do
      expect(Minigun::Cluster::TimeoutError).to eq(Minigun::ClusterTimeoutError)
    end

    it 'provides operation and timeout_seconds attributes' do
      error = Minigun::Cluster::TimeoutError.new(
        operation: 'waiting for workers',
        timeout_seconds: 30
      )
      expect(error.operation).to eq('waiting for workers')
      expect(error.timeout_seconds).to eq(30)
    end

    it 'generates a default message' do
      error = Minigun::Cluster::TimeoutError.new(
        operation: 'waiting for workers',
        timeout_seconds: 30
      )
      expect(error.message).to include('waiting for workers')
      expect(error.message).to include('30')
    end
  end
end
