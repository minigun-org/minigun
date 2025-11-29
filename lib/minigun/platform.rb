# frozen_string_literal: true

module Minigun
  # Platform detection methods
  module Platform
    extend self

    # Check if running on Windows
    def windows?
      return @windows if defined?(@windows)

      @windows = Gem.win_platform?
    end

    # Check if running on JRuby
    def jruby?
      return @jruby if defined?(@jruby)

      @jruby = RUBY_ENGINE == 'jruby'
    end

    # Check if running on TruffleRuby
    def truffleruby?
      return @truffleruby if defined?(@truffleruby)

      @truffleruby = RUBY_ENGINE == 'truffleruby'
    end

    # Check if platform supports forking
    def fork?
      return @fork if defined?(@fork)

      @fork = Process.respond_to?(:fork) && !truffleruby?
    end

    # Check if async gem is available for fiber-based concurrency
    def fibers?
      return @fibers if defined?(@fibers)

      @fibers = begin
        require 'async'
        require 'async/semaphore'
        require 'async/barrier'
        true
      rescue LoadError
        false
      end
    end
  end
end
