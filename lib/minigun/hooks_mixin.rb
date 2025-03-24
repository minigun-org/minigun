# frozen_string_literal: true

module Minigun
  # A lightweight hook system mixin that adds before/after/around hooks to any class
  module HooksMixin
    # Hook types that can be registered
    HOOK_TYPES = [:before, :after, :around].freeze
    
    def self.included(base)
      base.extend(ClassMethods)
      
      # Initialize the hooks storage
      base.class_eval do
        @_hook_points = []
        @_hooks = {}
      end
    end
    
    module ClassMethods
      attr_reader :_hook_points, :_hooks
      
      # Register hook points for this class
      # @param points [Array<Symbol>] The hook points to register
      def register_hook_points(*points)
        @_hook_points ||= []
        @_hooks ||= {}
        
        points.each do |point|
          @_hook_points << point.to_sym unless @_hook_points.include?(point.to_sym)
          
          # Define class methods for each hook type and point
          HOOK_TYPES.each do |type|
            method_name = "#{type}_#{point}"
            
            # Skip if method already defined
            next if respond_to?(method_name)
            
            # Define the method
            singleton_class.class_eval do
              define_method(method_name) do |method_or_proc = nil, &block|
                set_hook(point, type, method_or_proc, &block)
              end
            end
          end
        end
      end
      
      # Add a before hook
      def before(point, method_or_proc = nil, &block)
        set_hook(point, :before, method_or_proc, &block)
      end

      # Add an after hook
      def after(point, method_or_proc = nil, &block)
        set_hook(point, :after, method_or_proc, &block)
      end

      # Add an around hook
      def around(point, method_or_proc = nil, &block)
        set_hook(point, :around, method_or_proc, &block)
      end
      
      # Set a hook for a specific point and type
      # @param point [Symbol] The hook point
      # @param type [Symbol] The hook type (:before, :after, :around)
      # @param method_or_proc [Symbol, Proc] A method name or proc to call
      # @param block [Block] A block to execute
      def set_hook(point, type, method_or_proc = nil, &block)
        @_hooks ||= {}
        @_hooks[point] ||= { before: [], after: [], around: [] }
        
        # Add the hook
        hook = if block_given?
                 { block: block }
               elsif method_or_proc.is_a?(Symbol)
                 { method: method_or_proc }
               elsif method_or_proc.respond_to?(:call)
                 { proc: method_or_proc }
               else
                 raise ArgumentError, "Hook must be a method name, proc or block"
               end
        
        @_hooks[point][type] << hook
      end
      
      # Get all hooks for a specific point
      # @param point [Symbol] The hook point
      # @return [Hash] The hooks for this point
      def get_hooks(point)
        @_hooks ||= {}
        @_hooks[point] || { before: [], after: [], around: [] }
      end
      
      # Clear all hooks for this class
      def clear_hooks
        @_hooks = {}
        @_hook_points.each do |point|
          @_hooks[point] = { before: [], after: [], around: [] }
        end
      end
      
      # Ensure hooks are properly inherited by subclasses
      def inherited(subclass)
        super
        subclass.instance_variable_set(:@_hook_points, @_hook_points.dup)
        subclass.instance_variable_set(:@_hooks, deep_copy_hooks(@_hooks))
      end
      
      private
      
      # Deep copy the hooks hash to avoid shared references between classes
      def deep_copy_hooks(hooks)
        return {} if hooks.nil?
        
        result = {}
        hooks.each do |point, types|
          result[point] = {}
          types.each do |type, hooks_array|
            result[point][type] = hooks_array.map(&:dup)
          end
        end
        result
      end
    end
    
    # Run a hook with before/after/around hooks
    # @param name [Symbol] The hook point name
    # @param args [Array] Arguments to pass to the hook
    # @yield The block to execute between before and after hooks
    # @return [Object] The result of the around hook or the yield
    def run_hook(name, *args, &block)
      # Get hooks for this point
      hooks = self.class.get_hooks(name)
      
      # Run before hooks
      before_hooks = hooks[:before] || []
      before_hooks.each { |hook| execute_hook(hook, args) }
      
      # Run around hooks or the block
      result = if hooks[:around] && hooks[:around].any?
                 # Chain around hooks
                 run_around_hooks(hooks[:around], args, &block)
               else
                 # No around hooks, just call the block
                 yield(*args) if block_given?
               end
      
      # Run after hooks
      after_hooks = hooks[:after] || []
      after_hooks.each { |hook| execute_hook(hook, args) }
      
      # Return the result
      result
    end
    
    private
    
    # Execute a single hook
    def execute_hook(hook, args)
      if hook[:method]
        if respond_to?(hook[:method])
          send(hook[:method], *args)
        end
      elsif hook[:proc]
        instance_exec(*args, &hook[:proc])
      elsif hook[:block]
        instance_exec(*args, &hook[:block])
      end
    end
    
    # Run around hooks by chaining them
    def run_around_hooks(hooks, args, &block)
      return yield(*args) if hooks.empty?
      
      # Create a chain of around hooks, innermost first
      chain = lambda do |index=0|
        if index >= hooks.size
          # When we've gone through all hooks, call the original block
          yield(*args) 
        else
          # Get the current hook
          hook = hooks[hooks.size - index - 1]
          
          # Execute the hook with our context block
          if hook[:method] && respond_to?(hook[:method])
            # Use a method
            send(hook[:method], *args) do
              chain.call(index + 1)
            end
          elsif hook[:proc]
            # Use a lambda/proc
            instance_exec(*args) do 
              hook[:proc].call(*args) do
                chain.call(index + 1)
              end
            end
          elsif hook[:block]
            # Use a block directly
            instance_exec(*args) do
              hook_block = hook[:block]
              instance_eval do
                hook_block.call(*args) do 
                  chain.call(index + 1)
                end
              end
            end
          else
            # No valid hook, continue the chain
            chain.call(index + 1)
          end
        end
      end
      
      # Start the chain
      chain.call
    end
  end
end 