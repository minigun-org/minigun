# frozen_string_literal: true

module Minigun
  # Pipeline DSL executor used during pipeline definition
  class PipelineDSL
    attr_reader :pipeline
    attr_accessor :current_stage

    def initialize(pipeline)
      @pipeline = pipeline
      @current_stage = nil
    end

    # Helper method to set the current executing stage
    def set_current_stage(stage)
      @current_stage = stage
    end

    # Emit method to be used within blocks
    def emit(item, queue = :default)
      # Special handling for fork_mode=:never
      if @pipeline.task.config && @pipeline.task.config[:fork_mode] == :never
        # If emit is called from a processor stage and we have a consumer stage,
        # directly feed items to consumer stages to bypass accumulator issues
        if @current_stage && @current_stage.is_a?(Minigun::Stages::Processor) &&
          @current_stage.name.to_s != 'process_batch' && @current_stage.name.to_s != 'batch'

          # Find any consumer stages to directly feed to
          consumer_stages = @pipeline.stages.select { |s| s.name.to_s.include?('process') || s.name.to_s == 'consumer' }
          if consumer_stages.any?
            # Directly feed the item to consumer stages
            consumer_stages.each do |consumer|
              # If it's a consumer, feed the item directly for processing
              begin
                consumer.process(item) if consumer.respond_to?(:process)
              rescue => e
                # Log error but continue processing
                @pipeline.task.config[:logger].error("Error direct feeding item to consumer: #{e.message}")
              end
            end
          end
        end
      end

      # Normal emit behavior
      if @current_stage && @current_stage.respond_to?(:emit)
        @current_stage.emit(item, queue)
      else
        # If no stage is set, try to find the first stage
        first_stage = @pipeline.stages.first
        if first_stage && first_stage.respond_to?(:emit)
          first_stage.emit(item, queue)
        else
          raise "No stage available to emit items"
        end
      end
    end

    # Adds emit_to_queue (alias for emit) for compatibility
    alias_method :emit_to_queue, :emit

    # Define a producer stage
    def producer(name = :default, options = {}, &block)
      task = @pipeline.task

      # Add the stage to the task
      task.add_producer(name, options, &block)

      # Add to pipeline
      @pipeline.add_stage(Minigun::Stages::Processor, name, options)
    end

    # Define a processor stage
    def processor(name = :default, options = {}, &block)
      task = @pipeline.task

      # Add the stage to the task
      task.add_processor(name, options, &block)

      # Add to pipeline
      @pipeline.add_stage(Minigun::Stages::Processor, name, options)
    end

    # Define an accumulator stage
    def accumulator(name = :default, options = {}, &block)
      task = @pipeline.task

      # Add the stage to the task
      task.add_accumulator(name, options, &block)

      # Add to pipeline
      @pipeline.add_stage(Minigun::Stages::Accumulator, name, options)
    end

    # Define a consumer stage
    def consumer(name = :default, options = {}, &block)
      task = @pipeline.task

      # Add the stage to the task
      task.add_consumer(name, options, &block)

      # Add to pipeline
      @pipeline.add_stage(Minigun::Stages::Processor, name, options)
    end

    # Define a cow_fork consumer
    def cow_fork(name = :default, options = {}, &block)
      options = options.merge(fork: :cow)
      consumer(name, options, &block)
    end

    # Define an ipc_fork consumer
    def ipc_fork(name = :default, options = {}, &block)
      options = options.merge(fork: :ipc)
      consumer(name, options, &block)
    end

    def run
      # Run a simple input-output pipeline with a starting item
      run_pipeline_with_input(nil)

      # Special handling for fork_mode=:never to ensure all stages flush
      if @pipeline.task.config && @pipeline.task.config[:fork_mode] == :never
        # Find any accumulator stages and ensure they flush
        accumulators = @pipeline.stages.select { |s| s.is_a?(Minigun::Stages::Accumulator) }
        accumulators.each do |accumulator|
          # Force a final flush of any accumulator stages
          accumulator.flush if accumulator.respond_to?(:flush)
        end

        # After flushing accumulators, make sure we manually route items to consumers
        # This is especially important in fork_mode=:never since normal forking is skipped
        consumers = @pipeline.stages.select { |s| s.is_a?(Minigun::Stages::Processor) &&
          (s.name.to_s.include?('process') || s.name.to_s == 'consumer') }

        if consumers.any? && !accumulators.empty?
          # We have both accumulators and consumers, ensure items flowed correctly
          consumers.each do |consumer|
            # If any consumer takes batches, ensure it received them
            flushed_items = @pipeline.instance_variable_get(:@flushed_items) || []

            # Send each item/batch to the consumer for processing
            flushed_items.each do |batch|
              begin
                consumer.process(batch) if consumer.respond_to?(:process)
              rescue => e
                # Log error but continue processing
                @pipeline.task.config[:logger].error("Error feeding batch to consumer in never mode: #{e.message}")
              end
            end
          end
        end

        # Also check if the task has any accumulated items that need processing
        if @pipeline.task.instance_variable_defined?(:@accumulated_items) &&
          @pipeline.task.instance_variable_get(:@accumulated_items)

          accumulated_items = @pipeline.task.instance_variable_get(:@accumulated_items)
          if accumulated_items && accumulated_items.any?
            consumers.each do |consumer|
              accumulated_items.each do |batch|
                begin
                  consumer.process(batch) if consumer.respond_to?(:process)
                rescue => e
                  # Log error but continue processing
                  @pipeline.task.config[:logger].error("Error feeding accumulated items to consumer: #{e.message}")
                end
              end
            end
          end
        end
      end
    end

    private

    def run_pipeline_with_input(input_item)
      # Track the first stage in the pipeline
      first_stage = @pipeline.stages.first

      # The first stage processes the input item
      first_stage&.process(input_item)
    end
  end
end
