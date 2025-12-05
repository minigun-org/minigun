# frozen_string_literal: true

source 'https://rubygems.org'

gemspec

gem 'fiddle', platforms: %i[windows]

# Optional dependencies
gem 'async', platforms: %i[ruby windows]
gem 'drb' # For distributed clustering (no longer in stdlib since Ruby 3.4)
gem 'msgpack'
gem 'rswim' # Optional: for gossip-based cluster discovery
gem 'tsort' # Will be removed from stdlib in Ruby 4.1

# Test dependencies
gem 'benchmark'
gem 'rake'
gem 'rspec'
gem 'rubocop'
gem 'rubocop-performance'
gem 'rubocop-rake'
gem 'rubocop-rspec'
