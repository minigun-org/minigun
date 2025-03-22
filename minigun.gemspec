# frozen_string_literal: true

require_relative "lib/minigun/version"

Gem::Specification.new do |spec|
  spec.name = "minigun"
  spec.version = Minigun::VERSION
  spec.authors = ["Your Name"]
  spec.email = ["your.email@example.com"]

  spec.summary = "Lightweight framework for rapid-fire batch job processing"
  spec.description = "Minigun is a lightweight framework for rapid-fire batch job processing using a Producer-Accumulator-Consumer pattern. It uses forking and threads to maximize system resource utilization."
  spec.homepage = "https://github.com/yourusername/minigun"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 2.6.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  spec.files = Dir.chdir(__dir__) do
    `git ls-files -z`.split("\x0").reject do |f|
      (f == __FILE__) || f.match(%r{\A(?:(?:bin|test|spec|features)/|\.(?:git|travis|circleci)|appveyor)})
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  # Dependencies
  spec.add_dependency "concurrent-ruby", "~> 1.1"
  spec.add_dependency "concurrent-ruby-edge", "~> 0.6"

  # Development dependencies
  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "rspec", "~> 3.0"
  spec.add_development_dependency "rubocop", "~> 1.21"
end
