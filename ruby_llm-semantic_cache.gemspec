# frozen_string_literal: true

require_relative "lib/ruby_llm/semantic_cache/version"

Gem::Specification.new do |spec|
  spec.name          = "ruby_llm-semantic_cache"
  spec.version       = RubyLLM::SemanticCache::VERSION
  spec.authors       = ["Chris Hasinski"]
  spec.email         = ["krzysztof.hasinski@gmail.com"]

  spec.summary       = "Semantic caching for RubyLLM applications"
  spec.description   = "Cache RubyLLM responses based on semantic similarity, not exact string matching. " \
                       "Reduces costs and latency by returning cached responses for semantically equivalent queries."
  spec.homepage      = "https://github.com/khasinski/ruby_llm-semantic_cache"
  spec.license       = "MIT"
  spec.required_ruby_version = ">= 2.7.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"

  spec.files = Dir.chdir(__dir__) do
    `git ls-files -z`.split("\x0").reject do |f|
      (File.expand_path(f) == __FILE__) ||
        f.start_with?(*%w[bin/ test/ spec/ features/ .git .github appveyor Gemfile])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  # Required dependencies
  spec.add_dependency "ruby_llm", ">= 1.0"

  # Optional: Redis backend
  spec.add_development_dependency "neighbor-redis", "~> 0.1"

  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "rspec", "~> 3.0"
  spec.add_development_dependency "rubocop", "~> 1.50"
end
