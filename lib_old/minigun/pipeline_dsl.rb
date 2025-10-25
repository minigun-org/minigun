# frozen_string_literal: true

module Minigun
  # DSL for defining pipelines in a more structured way
  module PipelineDSL
    # Define a pipeline with the given stages
    def pipeline(&block)
      @pipeline_definition = block
    end
    
    # Add a processor stage to the pipeline
    def processor(name, options = {}, &block)
      @pipeline ||= []
      @pipeline << {
        type: :processor,
        name: name,
        options: options,
        block: block
      }
    end
    alias_method :producer, :processor
    alias_method :consumer, :processor

    # Add an accumulator stage
    def accumulator(name, options = {}, &block)
      @pipeline ||= []
      @pipeline << {
        type: :accumulator,
        name: name,
        options: options,
        block: block
      }
    end
    
    # Add a cow_fork stage (consumer with :cow forking)
    def cow_fork(name, options = {}, &block)
      options = options.merge(fork: :cow)
      processor(name, options, &block)
    end
    
    # Add an ipc_fork stage (consumer with :ipc forking)
    def ipc_fork(name, options = {}, &block)
      options = options.merge(fork: :ipc)
      processor(name, options, &block)
    end
  end
end
