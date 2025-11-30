# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Minigun::Errors' do
  describe Minigun::Errors::BaseError do
    it 'inherits from StandardError' do
      expect(Minigun::Errors::BaseError.superclass).to eq(StandardError)
    end

    it 'is aliased as Minigun::Error' do
      expect(Minigun::Error).to eq(Minigun::Errors::BaseError)
    end

    it 'accepts a message' do
      error = Minigun::Errors::BaseError.new('test message')
      expect(error.message).to eq('test message')
    end

    it 'accepts context kwargs' do
      error = Minigun::Errors::BaseError.new('test', foo: 'bar', baz: 123)
      expect(error.context).to eq(foo: 'bar', baz: 123)
    end

    it 'provides detailed_message with context' do
      error = Minigun::Errors::BaseError.new('test message', foo: 'bar')
      expect(error.detailed_message).to include('test message')
      expect(error.detailed_message).to include('foo="bar"')
    end

    it 'returns plain message when no context' do
      error = Minigun::Errors::BaseError.new('test message')
      expect(error.detailed_message).to eq('test message')
    end
  end

  describe 'Configuration Errors' do
    describe Minigun::Errors::ConfigurationError do
      it 'inherits from BaseError' do
        expect(Minigun::Errors::ConfigurationError.superclass).to eq(Minigun::Errors::BaseError)
      end

      it 'is aliased as Minigun::ConfigurationError' do
        expect(Minigun::ConfigurationError).to eq(Minigun::Errors::ConfigurationError)
      end
    end

    describe Minigun::Errors::StageNameConflict do
      it 'inherits from ConfigurationError' do
        expect(Minigun::Errors::StageNameConflict.superclass).to eq(Minigun::Errors::ConfigurationError)
      end

      it 'is aliased as Minigun::StageNameConflictError' do
        expect(Minigun::StageNameConflictError).to eq(Minigun::Errors::StageNameConflict)
      end

      it 'provides stage_name and pipeline_name attributes' do
        error = Minigun::Errors::StageNameConflict.new(
          stage_name: :processor,
          pipeline_name: 'main'
        )
        expect(error.stage_name).to eq(:processor)
        expect(error.pipeline_name).to eq('main')
      end

      it 'generates a default message from attributes' do
        error = Minigun::Errors::StageNameConflict.new(
          stage_name: :processor,
          pipeline_name: 'main'
        )
        expect(error.message).to include('processor')
        expect(error.message).to include('main')
      end

      it 'accepts a custom message' do
        error = Minigun::Errors::StageNameConflict.new('custom message')
        expect(error.message).to eq('custom message')
      end
    end

    describe Minigun::Errors::AmbiguousRouting do
      it 'inherits from ConfigurationError' do
        expect(Minigun::Errors::AmbiguousRouting.superclass).to eq(Minigun::Errors::ConfigurationError)
      end

      it 'is aliased as Minigun::AmbiguousRoutingError' do
        expect(Minigun::AmbiguousRoutingError).to eq(Minigun::Errors::AmbiguousRouting)
      end

      it 'provides stage_name and candidates attributes' do
        error = Minigun::Errors::AmbiguousRouting.new(
          stage_name: :transform,
          candidates: %w[pipeline_a.transform pipeline_b.transform]
        )
        expect(error.stage_name).to eq(:transform)
        expect(error.candidates).to eq(%w[pipeline_a.transform pipeline_b.transform])
      end

      it 'generates a default message' do
        error = Minigun::Errors::AmbiguousRouting.new(
          stage_name: :transform,
          candidates: %w[a b]
        )
        expect(error.message).to include('transform')
        expect(error.message).to include('2 matches')
      end
    end

    describe Minigun::Errors::InvalidOption do
      it 'inherits from ConfigurationError' do
        expect(Minigun::Errors::InvalidOption.superclass).to eq(Minigun::Errors::ConfigurationError)
      end

      it 'is aliased as Minigun::InvalidOptionError' do
        expect(Minigun::InvalidOptionError).to eq(Minigun::Errors::InvalidOption)
      end

      it 'provides option_name, value, and expected attributes' do
        error = Minigun::Errors::InvalidOption.new(
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
    describe Minigun::Errors::PipelineError do
      it 'inherits from BaseError' do
        expect(Minigun::Errors::PipelineError.superclass).to eq(Minigun::Errors::BaseError)
      end

      it 'is aliased as Minigun::PipelineError' do
        expect(Minigun::PipelineError).to eq(Minigun::Errors::PipelineError)
      end

      it 'provides pipeline_name attribute' do
        error = Minigun::Errors::PipelineError.new('test', pipeline_name: 'main')
        expect(error.pipeline_name).to eq('main')
      end
    end

    describe Minigun::Errors::CyclicDependency do
      it 'inherits from PipelineError' do
        expect(Minigun::Errors::CyclicDependency.superclass).to eq(Minigun::Errors::PipelineError)
      end

      it 'is aliased as Minigun::CyclicDependencyError' do
        expect(Minigun::CyclicDependencyError).to eq(Minigun::Errors::CyclicDependency)
      end

      it 'provides from_stage and to_stage attributes' do
        error = Minigun::Errors::CyclicDependency.new(
          from_stage: :a,
          to_stage: :b
        )
        expect(error.from_stage).to eq(:a)
        expect(error.to_stage).to eq(:b)
      end

      it 'generates a default message' do
        error = Minigun::Errors::CyclicDependency.new(
          from_stage: :a,
          to_stage: :b
        )
        expect(error.message).to include('a')
        expect(error.message).to include('b')
        expect(error.message).to include('cycle')
      end
    end

    describe Minigun::Errors::UnresolvedReference do
      it 'inherits from PipelineError' do
        expect(Minigun::Errors::UnresolvedReference.superclass).to eq(Minigun::Errors::PipelineError)
      end

      it 'is aliased as Minigun::UnresolvedReferenceError' do
        expect(Minigun::UnresolvedReferenceError).to eq(Minigun::Errors::UnresolvedReference)
      end

      it 'provides reference and available_stages attributes' do
        error = Minigun::Errors::UnresolvedReference.new(
          pipeline_name: 'main',
          reference: :missing,
          available_stages: %i[a b c]
        )
        expect(error.reference).to eq(:missing)
        expect(error.available_stages).to eq(%i[a b c])
      end
    end

    describe Minigun::Errors::SerializationFailed do
      it 'inherits from PipelineError' do
        expect(Minigun::Errors::SerializationFailed.superclass).to eq(Minigun::Errors::PipelineError)
      end

      it 'is aliased as Minigun::SerializationError' do
        expect(Minigun::SerializationError).to eq(Minigun::Errors::SerializationFailed)
      end

      it 'provides item_class and original_error attributes' do
        original = TypeError.new('cannot serialize')
        error = Minigun::Errors::SerializationFailed.new(
          item_class: 'Proc',
          original_error: original
        )
        expect(error.item_class).to eq('Proc')
        expect(error.original_error).to eq(original)
      end
    end
  end

  describe 'Execution Errors' do
    describe Minigun::Errors::ExecutionError do
      it 'inherits from BaseError' do
        expect(Minigun::Errors::ExecutionError.superclass).to eq(Minigun::Errors::BaseError)
      end

      it 'is aliased as Minigun::ExecutionError' do
        expect(Minigun::ExecutionError).to eq(Minigun::Errors::ExecutionError)
      end
    end

    describe Minigun::Errors::StageError do
      it 'inherits from ExecutionError' do
        expect(Minigun::Errors::StageError.superclass).to eq(Minigun::Errors::ExecutionError)
      end

      it 'is aliased as Minigun::StageError' do
        expect(Minigun::StageError).to eq(Minigun::Errors::StageError)
      end

      it 'provides stage_name attribute' do
        error = Minigun::Errors::StageError.new('test', stage_name: :processor)
        expect(error.stage_name).to eq(:processor)
      end
    end

    describe Minigun::Errors::ItemProcessingFailed do
      it 'inherits from StageError' do
        expect(Minigun::Errors::ItemProcessingFailed.superclass).to eq(Minigun::Errors::StageError)
      end

      it 'is aliased as Minigun::ItemProcessingError' do
        expect(Minigun::ItemProcessingError).to eq(Minigun::Errors::ItemProcessingFailed)
      end

      it 'provides item and original_error attributes' do
        original = RuntimeError.new('boom')
        original.set_backtrace(['line1', 'line2'])
        error = Minigun::Errors::ItemProcessingFailed.new(
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
        error = Minigun::Errors::ItemProcessingFailed.new(
          stage_name: :processor,
          item: { id: 1 },
          original_error: original
        )
        expect(error.backtrace).to eq(['line1', 'line2'])
      end
    end

    describe Minigun::Errors::RetryExhausted do
      it 'inherits from StageError' do
        expect(Minigun::Errors::RetryExhausted.superclass).to eq(Minigun::Errors::StageError)
      end

      it 'is aliased as Minigun::RetryExhaustedError' do
        expect(Minigun::RetryExhaustedError).to eq(Minigun::Errors::RetryExhausted)
      end

      it 'provides attempts and original_error attributes' do
        original = RuntimeError.new('network error')
        error = Minigun::Errors::RetryExhausted.new(
          stage_name: :api_call,
          attempts: 3,
          original_error: original
        )
        expect(error.attempts).to eq(3)
        expect(error.original_error).to eq(original)
      end

      it 'generates a default message' do
        original = RuntimeError.new('network error')
        error = Minigun::Errors::RetryExhausted.new(
          attempts: 3,
          original_error: original
        )
        expect(error.message).to include('3 attempts')
        expect(error.message).to include('network error')
      end
    end

    describe Minigun::Errors::HookFailed do
      it 'inherits from ExecutionError' do
        expect(Minigun::Errors::HookFailed.superclass).to eq(Minigun::Errors::ExecutionError)
      end

      it 'is aliased as Minigun::HookError' do
        expect(Minigun::HookError).to eq(Minigun::Errors::HookFailed)
      end

      it 'provides hook_type, stage_name, and original_error attributes' do
        original = RuntimeError.new('hook failed')
        error = Minigun::Errors::HookFailed.new(
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
        error = Minigun::Errors::HookFailed.new(
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
        error = Minigun::Errors::HookFailed.new(
          hook_type: :before_run,
          original_error: original
        )
        expect(error.message).to include('before_run')
        expect(error.stage_name).to be_nil
      end
    end

    describe Minigun::Errors::CircuitBreakerOpen do
      it 'inherits from ExecutionError' do
        expect(Minigun::Errors::CircuitBreakerOpen.superclass).to eq(Minigun::Errors::ExecutionError)
      end

      it 'is aliased as Minigun::CircuitBreakerOpenError' do
        expect(Minigun::CircuitBreakerOpenError).to eq(Minigun::Errors::CircuitBreakerOpen)
      end

      it 'provides circuit_name and retry_after attributes' do
        error = Minigun::Errors::CircuitBreakerOpen.new(
          circuit_name: :api,
          retry_after: 30.5
        )
        expect(error.circuit_name).to eq(:api)
        expect(error.retry_after).to eq(30.5)
      end

      it 'generates a default message' do
        error = Minigun::Errors::CircuitBreakerOpen.new(
          circuit_name: :api,
          retry_after: 30.5
        )
        expect(error.message).to include('api')
        expect(error.message).to include('30.5')
      end
    end
  end

  describe 'Cluster Errors' do
    describe Minigun::Errors::ClusterError do
      it 'inherits from BaseError' do
        expect(Minigun::Errors::ClusterError.superclass).to eq(Minigun::Errors::BaseError)
      end

      it 'is aliased as Minigun::ClusterError' do
        expect(Minigun::ClusterError).to eq(Minigun::Errors::ClusterError)
      end

      it 'is aliased as Minigun::Cluster::Error' do
        expect(Minigun::Cluster::Error).to eq(Minigun::Errors::ClusterError)
      end
    end

    describe Minigun::Errors::ClusterConnectionFailed do
      it 'inherits from ClusterError' do
        expect(Minigun::Errors::ClusterConnectionFailed.superclass).to eq(Minigun::Errors::ClusterError)
      end

      it 'is aliased as Minigun::ClusterConnectionError' do
        expect(Minigun::ClusterConnectionError).to eq(Minigun::Errors::ClusterConnectionFailed)
      end

      it 'is aliased as Minigun::Cluster::ConnectionError' do
        expect(Minigun::Cluster::ConnectionError).to eq(Minigun::Errors::ClusterConnectionFailed)
      end

      it 'provides uri and original_error attributes' do
        original = DRb::DRbConnError.new('connection refused')
        error = Minigun::Errors::ClusterConnectionFailed.new(
          uri: 'druby://localhost:9000',
          original_error: original
        )
        expect(error.uri).to eq('druby://localhost:9000')
        expect(error.original_error).to eq(original)
      end

      it 'generates a default message' do
        original = DRb::DRbConnError.new('connection refused')
        error = Minigun::Errors::ClusterConnectionFailed.new(
          uri: 'druby://localhost:9000',
          original_error: original
        )
        expect(error.message).to include('druby://localhost:9000')
        expect(error.message).to include('connection refused')
      end
    end

    describe Minigun::Errors::ClusterWorkerNotFound do
      it 'inherits from ClusterError' do
        expect(Minigun::Errors::ClusterWorkerNotFound.superclass).to eq(Minigun::Errors::ClusterError)
      end

      it 'is aliased as Minigun::ClusterWorkerNotFoundError' do
        expect(Minigun::ClusterWorkerNotFoundError).to eq(Minigun::Errors::ClusterWorkerNotFound)
      end

      it 'is aliased as Minigun::Cluster::WorkerNotFoundError' do
        expect(Minigun::Cluster::WorkerNotFoundError).to eq(Minigun::Errors::ClusterWorkerNotFound)
      end

      it 'provides stage_name and available_stages attributes' do
        error = Minigun::Errors::ClusterWorkerNotFound.new(
          stage_name: :missing,
          available_stages: %i[processor consumer]
        )
        expect(error.stage_name).to eq(:missing)
        expect(error.available_stages).to eq(%i[processor consumer])
      end
    end

    describe Minigun::Errors::ClusterDeliveryFailed do
      it 'inherits from ClusterError' do
        expect(Minigun::Errors::ClusterDeliveryFailed.superclass).to eq(Minigun::Errors::ClusterError)
      end

      it 'is aliased as Minigun::ClusterDeliveryError' do
        expect(Minigun::ClusterDeliveryError).to eq(Minigun::Errors::ClusterDeliveryFailed)
      end

      it 'is aliased as Minigun::Cluster::DeliveryError' do
        expect(Minigun::Cluster::DeliveryError).to eq(Minigun::Errors::ClusterDeliveryFailed)
      end

      it 'provides item_id, attempts, and last_error attributes' do
        original = RuntimeError.new('worker crashed')
        error = Minigun::Errors::ClusterDeliveryFailed.new(
          item_id: 'item-123',
          attempts: 3,
          last_error: original
        )
        expect(error.item_id).to eq('item-123')
        expect(error.attempts).to eq(3)
        expect(error.last_error).to eq(original)
      end

      it 'generates a default message' do
        error = Minigun::Errors::ClusterDeliveryFailed.new(
          item_id: 'item-123',
          attempts: 3
        )
        expect(error.message).to include('item-123')
        expect(error.message).to include('3 attempts')
      end
    end

    describe Minigun::Errors::ClusterTimedOut do
      it 'inherits from ClusterError' do
        expect(Minigun::Errors::ClusterTimedOut.superclass).to eq(Minigun::Errors::ClusterError)
      end

      it 'is aliased as Minigun::ClusterTimeoutError' do
        expect(Minigun::ClusterTimeoutError).to eq(Minigun::Errors::ClusterTimedOut)
      end

      it 'is aliased as Minigun::Cluster::TimeoutError' do
        expect(Minigun::Cluster::TimeoutError).to eq(Minigun::Errors::ClusterTimedOut)
      end

      it 'provides operation and timeout_seconds attributes' do
        error = Minigun::Errors::ClusterTimedOut.new(
          operation: 'waiting for workers',
          timeout_seconds: 30
        )
        expect(error.operation).to eq('waiting for workers')
        expect(error.timeout_seconds).to eq(30)
      end

      it 'generates a default message' do
        error = Minigun::Errors::ClusterTimedOut.new(
          operation: 'waiting for workers',
          timeout_seconds: 30
        )
        expect(error.message).to include('waiting for workers')
        expect(error.message).to include('30')
      end
    end
  end
end
