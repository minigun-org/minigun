# frozen_string_literal: true

require_relative 'lib/minigun/version'

Gem::Specification.new do |spec|
  spec.name = 'minigun'
  spec.version = Minigun::VERSION
  spec.authors = ['Johnny Shields']
  spec.email = ['johnny.shields@gmail.com']
  spec.summary = 'Lightweight framework for rapid-fire batch job processing'
  spec.description = 'Minigun is a lightweight framework for rapid-fire batch job processing, using forking and multi-threading to maximize system resource utilization.'
  spec.homepage = 'https://github.com/tablecheck/minigun'
  spec.license = 'MIT'
  spec.required_ruby_version = '>= 3.0.0'
  spec.files = Dir.glob('lib/**/*') + %w[LICENSE README]
  spec.require_paths = ['lib']
  spec.metadata['homepage_uri'] = spec.homepage
  spec.metadata['source_code_uri'] = spec.homepage
  spec.metadata['changelog_uri'] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata['rubygems_mfa_required'] = 'true'

  spec.add_dependency 'concurrent-ruby', '~> 1.1'
end
