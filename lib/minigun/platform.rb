# frozen_string_literal: true

module Minigun
  # Platform detection methods
  module Platform
    extend self

    # Returns true if running on Linux
    def linux?
      return @linux if defined?(@linux)

      @linux = RUBY_PLATFORM.include?('linux')
    end

    # Returns true if running on macOS
    def macos?
      return @macos if defined?(@macos)

      @macos = RUBY_PLATFORM.include?('darwin')
    end

    # Returns true if running on Windows
    def windows?
      return @windows if defined?(@windows)

      @windows = Gem.win_platform?
    end

    # Returns true if running on JRuby
    def jruby?
      return @jruby if defined?(@jruby)

      @jruby = RUBY_ENGINE == 'jruby'
    end

    # Returns true if running on TruffleRuby
    def truffleruby?
      return @truffleruby if defined?(@truffleruby)

      @truffleruby = RUBY_ENGINE == 'truffleruby'
    end

    # Returns true if platform supports forking
    def fork?
      return @fork if defined?(@fork)

      @fork = Process.respond_to?(:fork) && !truffleruby?
    end

    # Returns true if async gem is available for fiber-based concurrency
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

    # Returns true if Ractor::Port is available (Ruby 4.0+)
    def ractors?
      return @ractors if defined?(@ractors)

      @ractors = !!defined?(::Ractor::Port)
    end
  end
end
