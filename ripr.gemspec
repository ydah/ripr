# frozen_string_literal: true

require_relative "lib/ripr/version"

Gem::Specification.new do |spec|
  spec.name = "ripr"
  spec.version = Ripr::VERSION
  spec.authors = ["Yudai Takada"]
  spec.email = ["t.yudai92@gmail.com"]

  spec.summary = "Mutation testing with reach and infection diagnostics for Ruby"
  spec.description = "Find missing inputs and assertions with mutation switching and per-test infection probes."
  spec.homepage = "https://github.com/ydah/ripr"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.3"
  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "#{spec.homepage}/tree/main"

  spec.metadata["rubygems_mfa_required"] = "true"
  spec.files = Dir["lib/**/*.rb", "lib/ripr/reporters/assets/*", "exe/*", "schema/*", "skills/**/*",
                   "README.md", "LICENSE.txt", "CHANGELOG.md"]
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "prism", ">= 1.0", "< 3"
end
